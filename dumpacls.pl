#!/usr/bin/perl

use strict;

use Cwd;
use String::ShellQuote;

my $fs_cmd = '/usr/bin/fs';

my $path = $ARGV[0];
my $cwd = cwd();
if ($path !~ m/^\//) {
	# if path is not absolute
	$path = $cwd . $path
}

# strip tailing '/' from given path
$path =~ s/\/$//;

print "Dumping acls for  $path\n\n";

my $volume = get_volume($path);

dumpacl($path);
walkdir($path);

sub walkdir {
	my $path = shell_quote($_[0]);
	
	opendir(DIR, $path);
	my @entries = readdir(DIR);
	closedir(DIR);

	# this gets every entry underneath
	foreach my $entry (@entries) {
		if ($entry ne "." and $entry ne "..") {
			$entry = $path . "/" . $entry;
			if ( -d $entry and ! -l $entry) {
				#&processdir($entry, \%volstack, $depth);	
				next if get_volume($entry) ne $volume;
				dumpacl($entry);
				walkdir($entry);
			}
		}
	}
}

sub dumpacl {
	print `$fs_cmd listacl $_[0]`;
	print "--\n";
}

sub get_volume {
	my $dir = $_[0];
	my $listacl = `$fs_cmd exam $dir 2>/dev/null`;
	if ($listacl =~ m/.*contained in volume (.+)/) {
		return $1;
	} else {
		return 0;
	}
}
