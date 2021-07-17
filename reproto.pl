#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Data::Dumper;

my $gobin_path = shift @ARGV;
my $destdir_path = shift @ARGV;

die "Usage: $0 /path/to/go.bin /path/to/destdir" if (!$destdir_path);
die "Destination directory $destdir_path must exist" if(!-d $destdir_path);

my $gdb_functions = build_gdb_functions($gobin_path, $destdir_path);
my $proto_functions = parse_gdb_functions_for_proto($gdb_functions);

#print Dumper($proto_functions); exit;
my $gobin_buf = read_gobin($gobin_path);
my $proto_msgs = parse_gobin_for_proto_messages($gobin_buf);
# print Dumper($proto_msgs); exit;
my $proto_oneofs = parse_gobin_for_oneof_messages($gobin_buf);
#print Dumper($proto_oneofs);exit;

my $type_hints = disassemble_binary($gobin_path);
# print Dumper($type_hints); exit;

my $protos = reconstruct_protos($proto_functions, $proto_msgs, $proto_oneofs, $type_hints);
#print Dumper($protos);
save_protos($destdir_path, $protos);

sub reconstruct_protos {
	my ($proto_functions, $proto_msgs, $proto_oneofs, $type_hints) = @_;
	my %re;
	for my $basename (keys %$proto_functions) {
		my $pf = $proto_functions->{$basename};
		my $proto_str = "
// original: $pf->{path}

syntax = \"proto3\";

option go_package = \"$pf->{repo}->{shortname}/$pf->{repo}->{relpath_to_dir}\";

";

		if($proto_functions->{$basename}->{msg}) {

            my %oneof_types;
			my %oneof_names;

            # void github.com/irsl/sth.(*SampleMessage_Foo).isSampleMessage_TestOneof;			
			for my $msg (@{$proto_functions->{$basename}->{msg}}) {
				next if($msg !~ /^.+\.\(\*(.+?)_([A-Za-z0-9]+)\)\.is([a-zA-Z0-9_]+)_([A-Za-z0-9]+)$/);
				my $go_msg_type = $1;
				my $go_field_name = $2;
				my $go_msg_type_again = $3;
				my $go_oneof_go_name = $4;
				# print "$go_msg_type, $go_field_name, $go_msg_type_again, $go_oneof_go_name\n";
				next if($go_msg_type_again ne $go_msg_type);
				next if(!$proto_oneofs->{$go_oneof_go_name});
				
				# this field belongs to a oneof!
				if(scalar @{$proto_oneofs->{$go_oneof_go_name}} != 1) {
					warn "We detected a oneof type, but it is uncertain what it actually belongs to: $go_msg_type, $go_field_name, $go_oneof_go_name";
					next;
				}
				my $proto_oneof_name = $proto_oneofs->{$go_oneof_go_name}->[0];
				$oneof_types{$go_msg_type}{$go_field_name} = $proto_oneof_name;
				push @{$oneof_names{$go_msg_type}{$proto_oneof_name}}, $go_field_name;
			}


			for my $msg (@{$proto_functions->{$basename}->{msg}}) {
				next if($msg !~ /^.+\.\(\*(.+?)\)\.Get([a-zA-Z0-9_]+)$/);
				my $go_msg_type = $1;
				my $go_field_name = $2;
				next if($oneof_types{$go_msg_type}{$go_field_name});
				# print "$go_msg_type - $go_field_name\n";
				push @{$oneof_names{$go_msg_type}{""}}, $go_field_name;
			}
			for my $go_msg_type (keys %oneof_names) {
				$proto_str .= "
message $go_msg_type {
";

				for my $oneof_name (keys %{$oneof_names{$go_msg_type}}) {
					if($oneof_name ne "") {
						$proto_str .= "   oneof $oneof_name {\n"
					}

					for my $go_field_name (@{$oneof_names{$go_msg_type}{$oneof_name}}) {
						my $msgs = $proto_msgs->{$go_field_name};
						if (scalar @$msgs > 1) {
							$proto_str .= "	// TODO: $go_field_name has multiple definitions!\n";
						} elsif(scalar @$msgs == 0) {
							$proto_str .= "	// ERROR: couldn't find annotations for $go_field_name\n";
						}
						for my $msg (@$msgs) {
							my $flagprefix = "";
							if(defined $msg->{rep}) {
								$flagprefix = "repeated ";
							}
							fix_up_proto_type($go_msg_type, $go_field_name, $msg, $type_hints);
							$proto_str .= "	$flagprefix$msg->{type} $msg->{name} = $msg->{tag};$msg->{remarks}\n";
						}
					}

					
					if($oneof_name ne "") {
						$proto_str .= "   }\n";
					}
				}

				$proto_str .= "
}
";

			}
		}
		if($proto_functions->{$basename}->{rpc}) {
			# each service method gets a _Handler defined, like:
			# void google.golang.org/grpc/examples/features/proto/echo._Echo_BidirectionalStreamingEcho_Handler(interface {}, google.golang.org/grpc.ServerStream, error);
			# in this example, the name of the service is Echo
			
			my %svcs;
			for my $symbol (@{$proto_functions->{$basename}->{rpc}}) {
				next if($symbol !~ /.+\._([a-zA-Z0-9]+)_(.+)_Handler\(/);
				push @{$svcs{$1}}, $2;
			}
			for my $svc (keys %svcs) {
				$proto_str .= "service $svc {\n";
				for my $method (@{$svcs{$svc}}) {
					$proto_str .= "   rpc $method(TODO) returns (TODO) {}\n";
				}
				$proto_str .= "}\n";
			}
		}

		$re{$basename} = $proto_str;
	}
	return \%re;
}

sub disassemble_binary {
	my $gobin_path = shift;
	
	my %re;
	# this is how a symbol definition starts:
	# 00000000004433c0 <runtime.getStackMap>:
	open my $cmd,'-|',"objdump --disassemble '$gobin_path'" or die $@;
	my $line;
	my $go_msg_type;
	my $go_field_name;
	my $capture = 0;
	while (defined($line=<$cmd>)) {
		if($line =~ /^[0-9a-f]+ <([^>]+)>:/) {
			$capture = 0;
			# new function begins
			my $fn_name = $1;
			# print "fun: $fn_name\n";
			next if($fn_name !~ /^.+\.\(\*(.+?)\)\.Get([a-zA-Z0-9_]+)$/);
			$go_msg_type = $1;
			$go_field_name = $2;
			$capture = 1;
		}
		elsif($capture) {
			my $type_guessed;
			# print "$line ($go_msg_type, $go_field_name)\n";
			if($line =~ /:\s+0f 57 c0/) {
				$type_guessed = "string";
			}
			elsif($line =~ /:\s+c7 44 24 10 00 00 00/) {
				$type_guessed = "int32";
			}
			elsif($line =~ /:\s+48 c7 44 24 10 00 00/) {
				$type_guessed = "TODO_another_proto_msg";
			}
			$re{$go_msg_type}{$go_field_name} = $type_guessed if($type_guessed);
		}
	}
	close $cmd;
	
	return \%re;
}

sub fix_up_proto_type {
	my $go_msg_type = shift;
	my $golang_field_name = shift;
	my $proto_msg = shift;
	my $type_hints = shift;
	
	if($proto_msg->{type} eq "bytes") {
		my $type_hint = $type_hints->{$go_msg_type}{$golang_field_name};
		if($type_hint) {
			$proto_msg->{type} = $type_hint;	
		} else {
			$proto_msg->{remarks} .= " // TODO: may be string or another proto message";
		}
	} elsif($proto_msg->{type} eq "varint") {
	    $proto_msg->{type} = "int32";
	}
}

sub save_protos {
	my ($destdir_path, $protos) = @_;
	for my $basename (keys %$protos) {
		my $proto_str = $protos->{$basename};
		my $fn = "$destdir_path/$basename.proto";
		open(my $x, ">$fn") or die "Cant open $fn: $!";
		print $x $proto_str;
		close($x);
	}
}

sub read_gobin {
	my $gobin_path = shift;
	open(my $x, "<$gobin_path") or die "Cant open $gobin_path: $!";
	binmode($x);
	my $l = -s $gobin_path;
	read($x, my $buf, $l);
	close($x);
	die "Unable to cache $gobin_path to memory" if(length($buf) != $l);
	return $buf;
}

sub parse_gobin_for_proto_messages {
	my $buf = shift;

    my %re;
	while($buf =~ /([a-zA-Z0-9_]+)\x00.protobuf:"(.+?)"/sg) {
		#print "found: $1, $2\n";
		my ($go_field_name, $go_proto_annotation) = ($1, $2);
		my $proto_attrs = parse_proto_annotation($go_proto_annotation);
		#print Dumper($proto_attrs);
		push @{$re{$go_field_name}}, $proto_attrs;
	}
	return \%re;
}

sub parse_gobin_for_oneof_messages {
	my $buf = shift;

    my %re;
	while($buf =~ /([a-zA-Z0-9_]+)\x00.protobuf_oneof:"(.+?)"/sg) {
		#print "found: $1, $2\n";
		my ($go_field_name, $go_oneof_name) = ($1, $2);
		push @{$re{$go_field_name}}, $go_oneof_name;
	}
	return \%re;
}

sub parse_proto_annotation {
	my $annotation = shift;
	my @s = split(",", $annotation);
	my %re;
	$re{"remarks"} = "";
	$re{"type"} = $s[0];
	$re{"tag"} = $s[1];
	for my $i (2..(scalar @s)-1) {
		my $k = $s[$i];
		my $v;
		if($k =~ /(.+?)=(.+)/) {
			($k, $v) = ($1, $2);
		}
		$re{$k} = $v;
	}
	$re{"tag"} = $s[1];
	return \%re;
}

sub parse_gdb_functions {
	my $filename = shift;
	open(my $x, "<$filename") or die "Cant open $filename: $!";
	my $recent_filename;
	my %re;
	while(<$x>){
		if(/^File (.+):$/) {
			$recent_filename = $1;
		}
		elsif(($recent_filename)&&(/\t+(.+);$/)) {
			push @{$re{$recent_filename}}, $1;
		}
	}
	close($x);
	return \%re;
}

sub parse_gdb_functions_for_proto {
	my $filename = shift;
	my $funs = parse_gdb_functions($filename);
	my %re;
	for my $f (keys %$funs) {
		my $b = basename($f);
		next if($b !~ m#(.+?)(_grpc)?\.pb\.go$#);
		my $proto_basename = $1;
		my $is_rpc = $2 ? 1 : 0;
		
		$re{$proto_basename}{"path"} = $f;
		if(($f =~ m#pkg/mod/(.+?)@(.+?)/(.+)#)||($f =~ m#go/src/(.+?)(?:@(.+?))?/(.+)#)) {
			$re{$proto_basename}{"repo"}{"shortname"} = $1;
			$re{$proto_basename}{"repo"}{"version"} = $2 || "";
			$re{$proto_basename}{"repo"}{"longname"} = $1.'@'.$re{$proto_basename}{"repo"}{"version"};
			$re{$proto_basename}{"repo"}{"relpath"} = $3;
			$re{$proto_basename}{"repo"}{"full"} = $re{$proto_basename}{"repo"}{"longname"}."/$3";
			if($re{$proto_basename}{"repo"}{"relpath"} =~ m#(.+)/#) {
			   $re{$proto_basename}{"repo"}{"relpath_to_dir"} = $1;
			}
			#print Dumper($re{$proto_basename}{"path"}, \$re{$proto_basename}{"repo"});
		}
		$re{$proto_basename}{$is_rpc ? "rpc" : "msg"} = $funs->{$f};
	}
	return \%re;
}

sub build_gdb_functions {
   my ($gobin_path, $destdir_path) = @_;

   my $gobin_name = basename($gobin_path);   
   my $gdb_functions_path = "$destdir_path/$gobin_name.gdb.functions";
   if (!-s $gdb_functions_path) { # already exist, reusing
      system("gdb -ex 'set pagination off' --eval-command='info functions' --batch '$gobin_path' > '$gdb_functions_path'");
   }
   return $gdb_functions_path;
}
