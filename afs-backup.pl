#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use Sys::Hostname;

#my ($tmp, @tmp_array, $file, %config, $i, $k, $v, $path);
#my ($mntpt, $type, $volume, $cell, %mounts_by_path, %mounts_by_volume);

my $hostname = hostname();

Getopt::Long::Configure('bundling');
GetOptions(
	'h' => \(my $opt_h = 0),
	'help' => \(my $opt_help = 0),
	'v|verbose' => \(my $opt_verbose = 0),
	'q|quiet' => \(my $opt_quiet = 0),
	'p|pretend' => \(my $opt_pretend = 0),
	'm|mode=s' => \(my $mode = 'none'),
	't|timing' => \(my $opt_timing = 0),
	'tsm-node-name=s' => \(my $tsmnode = $hostname),
	'force-hostname=s' => \($hostname = $hostname),
	'no-dumpacls' => \(my $opt_nodumpacl = 0),
	'no-dsmc' => \(my $opt_nodsmc = 0),
	'no-dumpvldb' => \(my $opt_nodumpvldb = 0),
	'no-lastbackup' => \(my $opt_nolastbackup = 0),
	'use-dotbackup' => \(my $opt_usedotbackup = 0),
	'use-volmountsdb' => \(my $opt_usevolmountsdb = 0)
);

my $vosbackup_cmd = 'vos backup';
if (defined($ENV{'VOSBACKUP_CMD'})) {
	$vosbackup_cmd = $ENV{'VOSBACKUP_CMD'};
}

my $shorthostname = $hostname;
$shorthostname =~ s/\..*//;

my $afsbackup = $ENV{'AFSBACKUP'};
if ($afsbackup !~ m/^\//) {
	print "AFSBACKUP should really be an absolute path\n\n";
	exit 1;
}


if ($opt_help) {
	exec('perldoc', '-t', $0) or die "Cannot feed myself to perldoc\n";
	exit 0;
} elsif ($mode eq "none" or $afsbackup eq "" or $opt_h) {
	print "Usage: $0 [-h] [--help] [-p|pretend] [-v|--verbose] [-q|--quiet] [-t|--timing] [--force-hostname HOSTNAME]	[--no-lastbackup]\n";
	print "-m|--mode [tsm|shadow|find-mounts|vosbackup|vosrelease|vosdump]\n\n";
	print "tsm options:\n";
	print "\t[--tsm-node-name NODENAME] -- Force tsm node to NODENAME\n";
	print "\t[--no-dumpacl] -- Don't recursively dump acls\n";
	print "\t[--no-dumpvldb] -- Don't dump the VLDB\n\n";
	print "\t[--use-dotbackup] -- Use BK volumes as snapshotroot (also requires -backuptree option to afsd)\n\n";
	print "Environment Variables:\n";
	print "\tAFSBACKUP -- root directory containing etc/ and var/\n";
	print "\tVOSBACKUP_CMD -- command to use to perform vos backup instead of 'vos backup'\n";
	print "\n";
	exit 0;
}

my $total_starttime = time();

if (!$opt_quiet) {
	print "=== afs-backup.pl ===\n\n";
}

use Config::General;
my $conf = new Config::General("$afsbackup/etc/hosts/$shorthostname/config.cfg");
if (!$conf) {
	print "Failed to read config file.\n";
	exit 1;
}
my %c = $conf->getall;

# get rid of any trailing slashes in basepath
$c{'basepath'} =~ s/\/$//;
foreach (keys %{$c{'vosbackup'}{'backup'}{'path'}}) {
	if ($_ !~ /^\//) {
		$_ = $c{'basepath'} . '/' . $_;
	}
}

if ($opt_verbose) {
	print "afsbackup = $afsbackup\n";
	print "hostname = $hostname\n";
	print "shorthostname = $shorthostname\n\n";
	use Data::Dumper;
	print "\n=== Configuration ===\n";
	print Dumper(\%c);
}

# read in mounts-by-path and mounts-by-volume
my (%mounts_by_path, %mounts_by_volume);
if ($mode ne 'find-mounts') {
	# mounts-by-foo is created either weekly or nightly, probably weekly
	if ($opt_usevolmountsdb) {
		use VolmountsDB;

		my $vdb = VolmountsDB->new(
			$c{'volmountsdb'}{'user'},
			$c{'volmountsdb'}{'password'},
			$c{'volmountsdb'}{'host'},
			$c{'volmountsdb'}{'db'},
			$c{'basepath'} . '/'
		);
		if (!$vdb) {
			print "Failed to connect to volmountsdb!\n";
			exit 1;
		}
		%mounts_by_path = $vdb->get_mounts_by_path();
		%mounts_by_volume = $vdb->get_mounts_by_vol();

	} else {
		%mounts_by_path = read_mounts_by_path("$afsbackup/var/mounts/mounts-by-path");
		%mounts_by_volume = read_mounts_by_volume("$afsbackup/var/mounts/mounts-by-volume");
	}

	if (keys(%mounts_by_path) le 0 or keys(%mounts_by_volume) le 0) {
		print "No mounts found! This is bad.\n";
		exit 1;
	}
	if ($opt_verbose) {
		print "Mounts by path:\n";
		foreach my $path (sort keys %mounts_by_path) {
			printf "\t%s = %s\n", $path, $mounts_by_path{$path}{'volname'};
		}

		print "Mounts by volume:\n";
		foreach my $volume (sort keys %mounts_by_volume) {
			printf "\t%s (%s) = \n", $volume, $mounts_by_volume{$volume}{'cell'};
			foreach my $path (keys %{$mounts_by_volume{$volume}{'paths'}}) {
					printf "\t\t%s %s\n", $mounts_by_volume{$volume}{'paths'}{$path}, $path;
			}
		}
	}
}

my $exit = 0;
# switch over $mode
if ($mode eq 'tsm') {
	print "\nRequested mode tsm\n";
	$exit = mode_tsm();
} elsif ($mode eq 'vosbackup') {
	print "\nRequested mode vosbackup\n";
	$exit = mode_vosbackup();
} elsif ($mode eq 'find-mounts') {
	print "\nRequested mode find-mounts\n";
	if (@ARGV ne 1 or $ARGV[0] !~ /^\//) {
		print "-m find-mounts takes one argument: absolute path to traverse\n\n";
		exit 1;
	}
	$exit = mode_find_mounts($ARGV[0]);
} else {
	print "\nInvalid mode: $mode\n\n";
	exit 1;
}

if ($opt_timing) {
	printf "Execution time: %s s\n", time - $total_starttime;
}

print "$mode returned $exit\n";
exit $exit;

# accepts mounts_by_path-like hashref, hash of regexes to check, keyed by regex
# returns: hash of volumes to back up, value -1 means explicitly don't backup
sub match_by_path(\%\%) {
	my ($by_path, $r) = @_;
	my (%return);
	
	foreach my $path (keys %$by_path) {
		next if $by_path->{$path}{'mtpttype'} ne '#'; # we only want normal mountpoints
		my $volume = $by_path->{$path}{'volname'};
		foreach (keys %$r) {
			my $regex = $_;
			my $exclude_from_backup = 0;
			if ($regex =~ m/^\!/) {
				$exclude_from_backup = 1;
				$regex =~ s/^\!//;
			}
			# normalize paths
			$path =~ s/\/+/\//; # get rid of duplicate /'s
			$path =~ s/\/$//; # remove any trailing /'s
			$regex =~ s/\/+/\//; # get rid of duplicate /'s
			$regex =~ s/\/$//; # remove any trailing /'s
			if ($path =~ m/$regex/) {
				if ($exclude_from_backup) {
					$return{$volume} = -1;
				} elsif (!defined $return{$volume}) {
					$return{$volume} = 1;
				}
			}
		}
	}
	return %return;
}

# accepts mounts_by_volume-like hashref, hash of regexes to check, keyed by regex
# returns: hash of volumes to back up, value -1 means explicitly don't backup
sub match_by_volume(\%\%) {
	my ($by_volume, $r) = @_;
	my (%return);
	
	foreach my $volume (keys %$by_volume) {
		foreach my $regex (keys %$r) {
			my $exclude_from_backup = 0;
			if ($regex =~ m/^\!/) {
				$exclude_from_backup = 1;
				$regex =~ s/^\!//;
			}
			if ($volume =~ m/$regex/) {
				if ($exclude_from_backup) {
					$return{$volume} = -1;
				} elsif (!defined $return{$volume}) {
					$return{$volume} = 1;
				}
			}
		}
	}
	return %return, 
}

# adds the results of match_by_*
# returns combined hash, negative values mean do not backup
sub add_match_by(\%\%) {
	my ($one, $two) = @_;

	my %return = %$one;
	# now we add two to return, adding values
	foreach (keys %$two) {
		if (defined $return{$_}) {
			$return{$_} = $return{$_} + $two->{$_};
		} else {
			$return{$_} = $two->{$_};
		}
	}
	return %return;
}

# return match_by_* type hash with excluded volumes removed
sub exclude_matched(%) {
	my (%in) = @_;

	my %return;
	foreach my $volume (keys %in) {
		if ($in{$volume} gt 0) {
			$return{$volume} = 1;
		}
	}
	return %return;
}
	
# return match_by_* type hash with volumes removed based on lastbackup times
sub exclude_lastbackup(\%$) {
	my ($in, $mode) = @_;
	my ($volume_to_check, %return);
	foreach my $volume (keys %$in ) {
		if ($opt_usedotbackup) {
			$volume_to_check = "$volume.backup";
		} else {
			$volume_to_check = $volume;
		}
		# not checking the .backup volume means we share lastupdate times between foo and foo.backup
		# but we could lose data when switching to use .backup if the volume is updated between the time we
		# backed up the .backup and the time we switched
		if (get_vol_updatedate($volume_to_check) gt get_lastbackup($mode, $volume)) {
			$return{$volume} = 1;
		} else {
			if (!$opt_quiet) {
				print "Skipping volume $volume ($volume_to_check) because it hasn't been updated since it was last backed up\n";
			}
		}
	}
	return %return;
}

##
## TSM mode
##
sub mode_tsm {
	# massage config
	foreach (keys %{$c{'tsm'}{'backup'}{'path'}}) {
		if ($_ !~ /^\//) {
			$_ = $c{'basepath'} . '/' . $_;
		}
	}

	# start writing dsm.sys
	my $dsmsys = "$afsbackup/var/tmp/dsm.sys.$shorthostname";
	if ( -e $dsmsys) {
		cmd("rm -f $dsmsys");
	}
	if ( -e "$afsbackup/etc/common/dsm.sys.head") {
		cmd("cp $afsbackup/etc/common/dsm.sys.head $dsmsys");
	}
	if ( ! -e "$afsbackup/etc/hosts/$shorthostname/dsm.sys.head") {
		print "$afsbackup/etc/hosts/$shorthostname/dsm.sys.head does not exist!\n";
		exit 1;
	}
	cmd("cat $afsbackup/etc/hosts/$shorthostname/dsm.sys.head >> $dsmsys");

	if ( -e "$dsmsys" or $opt_pretend) {
		open (DSMSYS, '>>', $dsmsys);
		#print DSMSYS "INCLEXCL $inclexcl\n";
		# virtualmounts based on all afs mount points
		printf DSMSYS "VirtualMountPoint %s\n", $c{'basepath'};
		printf DSMSYS "VirtualMountPoint /afs\n";
		foreach (sort keys %mounts_by_path) {
			# skip mountpoints that we can't access. 
			# This might allow volumes to be backed up that we don't want, so be careful!
			next if ! -d $_; 			
			my $abspath = $_;
			printf DSMSYS "VirtualMountPoint %s\n", $abspath;
			if ($opt_usedotbackup) {
				my $relative_path = $abspath;
				$relative_path =~ s/$c{'basepath'}//;
				# when using afsd -backuptree, don't define virtualm's for .backup mounts
				# as they already don't exist
				if ($mounts_by_path{$abspath}{'volname'} !~ m/.+\.backup$/) {
					printf DSMSYS "VirtualMountPoint %s\n", 
						$c{'tsm'}{'tmp-mount-path'} . '/root.cell' . $relative_path ;
				}
			}
		}
	} else {
		print "Failed to create $dsmsys. This shouldn't happen.\n";
		exit 1;
	}

	my %backup_by_path = match_by_path(%mounts_by_path, %{$c{'tsm'}{'backup'}{'path'}});
	my %backup_by_volume = match_by_volume(%mounts_by_volume, %{$c{'tsm'}{'backup'}{'volume'}});
	my %backup_matched = add_match_by(%backup_by_path, %backup_by_volume);
	
	# remove volumes that were excluded (value < 0)
	%backup_matched = exclude_matched(%backup_matched);
	%backup_matched = exclude_lastbackup(%backup_matched, 'tsm');

	# get %backup_paths based on %backup_volumes, and the shortest normal path
	my (%backup_paths);
	foreach my $volume (keys %backup_matched) {
		foreach my $path (keys %{$mounts_by_volume{$volume}{'paths'}}) {
			next if $mounts_by_volume{$volume}{'paths'}{$path} ne '#'; # skip explicit RW mounts
			if (defined($backup_paths{$volume}) 
				and (length($mounts_by_volume{$volume}{'paths'}{$path}) 
					lt length($backup_paths{$volume}))) {
					$backup_paths{$volume} = $path;
			} else {
				$backup_paths{$volume} = $path;
			}
		}
	}

	# strip trailing slash off of the path for dsmc incr to work correctly
	foreach my $volume (keys %backup_paths) {
		$backup_paths{$volume} =~ s/\/$//;
	}
	
	# sanity check tsm-policy-order
	if ($c{'tsm'}{'policy'}{'order'} !~ /(path\s+volume)|(volume\s+path)/) {
		print "Syntax error in tsm-policy-order. Expecting one of \"path volume\" or \"volume path\"\n";
		exit 1;
	} 

	my %policy_by_volume;
	# determine management class to use
	foreach my $policy (split(/\s+/, $c{'tsm'}{'policy'}{'order'})) {
		if ($policy eq 'path') {
			foreach my $volume (keys %backup_paths) {
				my $path = $backup_paths{$volume};
				# run through tsm-policy-by-path in order of increasing length?
				foreach my $regex (sort { length $a <=> length $b || $a cmp $b } keys %{$c{'tsm'}{'policy'}{'path'}}) {
					if ($path =~ m/$regex/) {
						$policy_by_volume{$volume} = $c{'tsm'}{'policy'}{'path'}{$regex};
					}
				}
			}
		}
		if ($policy eq 'volume') {
			foreach my $volume (keys %backup_paths) {
				# run through tsm-policy-by-volume
				foreach my $regex (keys %{$c{'tsm'}{'policy'}{'volume'}}) {
					if ($volume =~ m/$regex/) {
						$policy_by_volume{$volume} = $c{'tsm'}{'policy'}{'volume'}{$regex};
					}
				}
			}
		}
	}

	# set default policy for those paths where we have no policy yet
	foreach my $volume (keys %backup_paths) {
		if (!defined($policy_by_volume{$volume}) or $policy_by_volume{$volume} eq '') {
			$policy_by_volume{$volume} = $c{'tsm'}{'policy'}{'default'};
		}
	}
			

	if (!$opt_quiet) {
		print "\n=== Paths/mountpoints to backup ===\n";
		print "PATH | VOLUME | MGMTCLASS\n";
		foreach my $volume (sort keys %backup_paths) {
			printf "%s | %s | %s\n", $backup_paths{$volume}, $volume, $policy_by_volume{$volume};
		}
		print "TOTAL: " . keys(%backup_paths) . " volumes selected out of " . keys(%backup_matched) . " candidate volumes. \n";
		print "There are " . keys(%mounts_by_volume) . " volumes total mounted within the cell.\n";
	}

	# default management class
	if ($c{'tsm'}{'policy'}{'default'} ne "") {
		printf DSMSYS "\n* Default management class (policy-default)\ninclude * %s\n\n", $c{'tsm'}{'policy'}{'default'};
	}
	# per-path management class
	print DSMSYS "\n* per-path management classes\n";
	foreach my $v (sort { length $a <=> length $b || $a cmp $b } keys %backup_paths) {
		if ($policy_by_volume{$v} ne '') {
			printf DSMSYS "INCLUDE %s/* %s\n", $v, $policy_by_volume{$v};
			printf DSMSYS "INCLUDE %s/.../* %s\n", $v, $policy_by_volume{$v};
		}
	}
	# because dsmc uses bottom-up processing for include/exclude, stick our inclexcl file at the end of dsm.sys
	cmd("cat $afsbackup/etc/common/exclude.list >> $dsmsys");
	cmd("cat $afsbackup/etc/hosts/$shorthostname/exclude.list >> $dsmsys");
	close (DSMSYS); # close dsm.sys.$tsmnode

	if (! cmd("cp $dsmsys /opt/tivoli/tsm/client/ba/bin/dsm.sys")) {
		print "Could not copy $dsmsys to /opt/tivoli/tsm/client/ba/bin/dsm.sys !\n";
		return 1;
	}
	
	# make sure a .backup volume exists for every volume
	# vos backup if not
	# then mount each volume
	if ($opt_usedotbackup) {
		if (!$opt_quiet) {
			print "\n=== Creating .backup volumes if needed ===\n";
		} 
		foreach my $v (sort keys %backup_paths) {
			if (!$opt_quiet) {
				print "Checking for BK volume for $v ...\n";
			}
			if (! cmd("vos exam $v.backup >/dev/null 2>&1")) {
				if ($opt_verbose) {
					print "No backup volume for $v. Will attempt to create.\n";
					cmd("$vosbackup_cmd $v");
				}
			}
		}
	}

	if ($opt_usedotbackup) {
		cmd("fs rmm $c{'tsm'}{'tmp-mount-path'}/root.cell >/dev/null 2>&1");
		cmd("fs mkm $c{'tsm'}{'tmp-mount-path'}/root.cell root.cell.backup");
	}

	# dump vldb
	if (!$opt_nodumpvldb) {
		print "\n=== Dumping VLDB metadata to $afsbackup/var/vldb/vldb.date ===\n";
		cmd("dumpvldb.sh $afsbackup/var/vldb/vldb.`date +%Y%m%d-%H%M%S`");
	}

	# dump acls
	if (!$opt_nodumpacl) {
		print "\n=== Dumping ACLs ===\n";
		foreach my $v (sort keys %backup_paths) {
			printf "[acl] %s (%s)\n", $backup_paths{$v}, $v;
			my $path;
			if ($opt_usedotbackup) {
				$path = $c{'tsm'}{'tmp-mount-path'} . '/' . $v;
				cmd("fs rmm $path >/dev/null 2>&1");
				cmd("fs mkm $path $v.backup");
			} else {
				$path = $backup_paths{$v};
			}
			cmd("dumpacls.pl $path > $afsbackup/var/acl/$v 2>/dev/null");
			if ($opt_usedotbackup) {
				cmd("fs rmm $path >/dev/null 2>&1");
			}
		}
	}

	# run dsmc incremental
	print "\n=== Running dsmc incremental ===\n";
	cmd("mv $afsbackup/var/log/dsmc.log.$shorthostname $afsbackup/var/log/dsmc.log.$shorthostname.last ; 
		mv $afsbackup/var/log/dsmc.error.$shorthostname $afsbackup/var/log/dsmc.error.$shorthostname.last");

	my $snapshotroot='';
	foreach my $v (sort keys %backup_paths) {
		printf "[dsmc] %s (%s)\n", $backup_paths{$v}, $v;
		if ($opt_usedotbackup) {
			if ($backup_paths{$v} eq $c{'basepath'}) {
				$snapshotroot = $c{'tsm'}{'tmp-mount-path'} . '/root.cell';
			} else {
				$backup_paths{$v} =~ m/$c{'basepath'}(.+)/; # grab the part of the path after basepath
				$snapshotroot = $c{'tsm'}{'tmp-mount-path'} . '/root.cell' . $1;
			}
			$snapshotroot = '-snapshotroot=' . $snapshotroot;
		}

		my $command = sprintf("dsmc incremental %s %s >> %s 2>&1",
			$backup_paths{$v}, 
			$snapshotroot,
			$afsbackup . '/var/log/dsmc.log.' . $shorthostname,
			$afsbackup . '/var/log/dsmc.error.' . $shorthostname);
		if (!$opt_nodsmc) {
			# dsmc can return weird values, so we don't check the exit status at all
			cmd($command);
			set_lastbackup('tsm', $v);
		} else {
			print "$command\n";
		}
	}

} # END mode_tsm()


##
## find-mounts mode
##
sub mode_find_mounts {
	my ($path) = @_;
	$path =~ s/\/$//; # get rid of trailing /
	my $filename = $path;
	$filename =~ s/^\///; # get rid of leading /
	$filename =~ s/\//-/g; # replace remaining /'s with -
	if (!$opt_quiet) {
		print "Going to get mounts for $path\n";
		print "Mounts will be put in $afsbackup/var/mounts/$filename-* and mounts-by-* will be updated\n";
	}
	if (cmd("afs-find-mounts.pl -lm $path $afsbackup/var/mounts/TMP-$filename")) {
		cmd("mv $afsbackup/var/mounts/TMP-$filename-by-volume $afsbackup/var/mounts/$filename-by-volume");
		cmd("mv $afsbackup/var/mounts/TMP-$filename-by-mount $afsbackup/var/mounts/$filename-by-mount");

		cmd("cat $afsbackup/var/mounts/*-by-mount > $afsbackup/var/mounts/mounts-by-path 2>/dev/null");
		cmd("cat $afsbackup/var/mounts/*-by-volume > $afsbackup/var/mounts/mounts-by-volume 2>/dev/null");
		return 0;
	}
	print "afs-find-mounts.pl failed for some reason\n";
	return 1;

} # END sub mode_find_mounts


##
## vosbackup mode
##
sub mode_vosbackup {
	my ($exclude_from_backup, @backup, %backup_hash, %nobackup);
	
	my %backup_by_path = match_by_path(%mounts_by_path, %{$c{'vosbackup'}{'path'}});
	my %backup_by_volume = match_by_volume(%mounts_by_volume, %{$c{'vosbackup'}{'volume'}});
	my %backup_matched = add_match_by(%backup_by_volume, %backup_by_path);
	
	# remove volumes that were excluded (value < 0)
	%backup_matched = exclude_matched(%backup_matched);
	%backup_matched = exclude_lastbackup(%backup_matched, 'vosbackup');
	
	if (!$opt_quiet) {
		print "\n=== volumes to vos backup ===\n";
		print "VOLUME\n";
		foreach (sort keys %backup_matched) {
			printf "%s\n", $_;
		}
	}

	my $return = 0;
	print "\n=== running vos backup ===\n";
	# actually run the vos backup command
	foreach my $volume (sort keys %backup_matched) {
		if (!$opt_quiet) {
			print "$vosbackup_cmd $volume\n";
		}
		if (!cmd("$vosbackup_cmd $volume")) {
			print "\tfailed\n";
			$return = 1;
		} else {
			set_lastbackup('vosbackup', $volume);
		}
	}
	return $return;
} # END sub mode_vosbackup()


##
## miscellaneous functions
##

sub cmd {
	my @command = @_;
	my (@output, $status, $starttime, $delta_t);

	if ($opt_pretend) {
		printf "[cmd] %s\n", @command;
		return 1;
	} elsif ($opt_timing) {
		$starttime = time();
	}

	$| = 1;
	my $pid = open (OUT, '-|');
	if (!defined $pid) {
		die "unable to fork: $!";
	} elsif ($pid eq 0) {
		open (STDERR, '>&STDOUT') or die "cannot dup stdout: $!";
		exec @command or print "cannot exec $command[0]: $!";
	} else {
		while (<OUT>) {
			if (! $opt_quiet) {
				print "$_";
			}
			push (@output, $_);
		}
		waitpid ($pid, 0);
		$status = $?;
		close OUT;
		if ($opt_timing) {
			$delta_t = time - $starttime;
			if ($delta_t > 5) {
				printf "(%s s)\n", $delta_t;
			}
		}
	}
	return ($status == 0);
}

sub read_file_single {
	my ($file) = @_;
	if ($opt_verbose) {
		print "reading in $file\n";
	}
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			next if /^\s*\#/; # skip comments
			next if /^\s*$/; # skip blank lines
			s/\n//;
			return $_;
		}
	} else {
		return 0;
	}
}

sub read_file_multi {
	my ($file) = @_;
	my @return = ();
	if ($opt_verbose) {
		print "reading in $file\n";
	}
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			next if /^\s*\#/; # skip comments
			next if /^\s*$/; # skip blank lines
			s/\n//;
			push @return, $_; 
		}
	}
	return @return;
}

sub read_mounts_by_volume {
	my ($file) = @_;
	my %return;
	my @paths = ();
	my ($vol, $cell, $path, $type);
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			# this shouldn't happen, but skip path lines
			next if /^\s*\#/;
			next if /^\s*\%/;
			# get the volume|cell line
			s/\n//;
			($vol, $cell) = split(/\|/, $_);
			@paths = (); # clear the paths
			while (<HANDLE>) {
				last if /^\s*$/; # blank lines mark end of this volume block
				# get the paths
				s/\n//;
				s/^\s*//;
				push @paths, $_;
			}
			$return{$vol}{'cell'} = $cell;
			foreach (@paths) {
				($type, $path) = split(/\s+/, $_);
				$return{$vol}{'paths'}{$path} = $type;
			}
		}
	}
	return %return;
}

sub read_mounts_by_path {
	my ($file) = @_;
	my %return;
	my @tmp_array;
	if ( -e "$file" ) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		while (<HANDLE>) {
			next if /^\s*$/; # skip blank lines
			s/\n//;
			push @tmp_array, [ split(/\|/, $_) ];
		}
	}
	for my $i (0 .. $#tmp_array) {
		my ($mntpt, $type, $volume, $cell) = @{$tmp_array[$i]};
		$return{$mntpt} = { 
			type => $type,
			volume => $volume,
			cell => $cell
		}
	}
	return %return;
}

sub get_lastbackup {
	my ($type, $volume) = @_;
	my $file = $afsbackup . '/var/lastbackup/' . $volume . '.' . $type;
	if ( -e "$file" and !$opt_nolastbackup) {
		open (HANDLE, '<', $file) or print "cannot open file $file: $!\n";
		local $_;
		while (<HANDLE>) {
			next if /^\s*\#/; # skip comments
			next if /^\s*$/; # skip blank lines
			s/\n//;
			close (HANDLE);
			return $_;
		}
	}
	return 0;
}

sub set_lastbackup {
	if (!$opt_pretend) {
		my ($type, $volume) = @_;
		my $file = $afsbackup . '/var/lastbackup/' . $volume . '.' . $type;
		open (HANDLE, ">$file") or print "cannot open file $file: $!\n";
		print HANDLE time;
		close (HANDLE);
	}
}

sub get_vol_updatedate {
	my ($volume) = @_;
	foreach (`vos exam -format $volume 2>&1`) {
		if (m/updateDate\s+(.+?)$/) {
			return $1;
		}
	}
	return 0;
}


__END__

=head1 NAME

afs-backup.pl - Performs various backup-type operations for AFS

=head1 SYNOPSIS

 afs-backup.pl OPTIONS

=head1 OPTIONS

=over 8

=item B<-h>, B<help>

Print this documentation

=item B<-v>, B<--verbose>

Say what we're doing at each step of the process

=item B<-q>, B<--quiet>

Only print the mounts by mount or by volume with no processing information. NOT mutually exclusive with --verbose

=item B<-l>, B<--by-volume>

Print mount points by volume name

=item B<-m>, B<--by-mount>

Print mount points by mount point path

=item B<PATH>

Path to dive into. This can either be relative or absolute. 

=cut
