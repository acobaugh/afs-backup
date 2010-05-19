#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use Sys::Hostname;
use Fcntl qw(:flock);

open(SELF, "<", $0) or die "Cannot open $0 - $!";
flock(SELF, LOCK_EX|LOCK_NB) or die "$0 - Already running.";


my %opt = ();
Getopt::Long::Configure('bundling');
GetOptions(\%opt, 
	'h', 
	'help',
	'mode=s',
	'force-hostname=s',
	'config=s'	
);

my $hostname;
if (defined $opt{'force-hostname'}) {
	$hostname = $opt{'force-hostname'};
} else {
	$hostname = hostname();
}
my $shorthostname = $hostname;
$shorthostname =~ s/\..*//;

my $AFSBACKUP = $ENV{'AFSBACKUP'};
if ($AFSBACKUP !~ m/^\//) {
	print "AFSBACKUP should really be an absolute path\n\n";
	exit 1;
}

if (defined $opt{'help'}) {
	exec('perldoc', '-t', $0) or die "Cannot feed myself to perldoc\n";
	exit 0;
} elsif (!defined $opt{'mode'} or $AFSBACKUP eq "" or defined $opt{'h'}) {
	print "Usage: $0 [-h] [--help] [--force-hostname HOSTNAME] [--config /path/to/config]\n";
	print "-m|--mode [tsm|shadow|vosbackup|vosrelease|vosdump]\n\n";
	print "\tAFSBACKUP -- root directory containing etc/ and var/\n";
	print "\n";
	exit 0;
}

my $total_starttime = time;

sub process_config(\%) {
	my ($c) = @_;
	# get rid of any trailing slashes in basepath
	$c->{'basepath'} =~ s/\/$//;

#	# add basepath to relative paths for vosbackup
#	my ($newkey, $oldkey);
#	foreach $oldkey (keys %{$c->{'vosbackup'}{'path'}}) {
#		$oldkey =~ s/^\s+//;
#		$oldkey =~ s/\s+$//;
#		if ($oldkey !~ /^\//) {
#			my $pre = '';
#			if ($oldkey =~ m/^!/) {
#				$oldkey =~ s/^!//;
#				$pre = '!';
#			}
#			$newkey = $pre . $c->{'basepath'} . '/' . $oldkey;
#		}
#		$oldkey =~ s/\/+/\//; # get rid of duplicate /'s
#		$oldkey =~ s/\/$//; # remove any trailing /'s
#		
#		$c->{'vosbackup'}{'path'}{$newkey} = delete $c->{'vosbackup'}{'path'}{$oldkey};
#	}
#	# add basepath to relative paths for tsm backup
#	foreach $oldkey (keys %{$c->{'tsm'}{'backup'}{'path'}}) {
#		$oldkey =~ s/^\s+//;
#		$oldkey =~ s/\s+$//;
#		if ($oldkey !~ /^\//) {
#			my $pre = '';
#			if ($oldkey =~ m/^!/) {
#				$oldkey =~ s/^!//;
#				$pre = '!';
#			}
#			$newkey = $pre . $c->{'basepath'} . '/' . $oldkey;
#		}
#		$oldkey =~ s/\/+/\//; # get rid of duplicate /'s
#		$oldkey =~ s/\/$//; # remove any trailing /'s
#		
#		$c->{'tsm'}{'backup'}{'path'}{$newkey} = delete $c->{'tsm'}{'backup'}{'path'}{$oldkey};
#	}
#	# add basepath to relative paths for tsm policy
#	foreach $oldkey (keys %{$c->{'tsm'}{'policy'}{'path'}}) {
#		$oldkey =~ s/^\s+//;
#		$oldkey =~ s/\s+$//;
#		if ($oldkey !~ /^\//) {
#			$newkey = $c->{'basepath'} . '/' . $oldkey;
#		}
#		$oldkey =~ s/\/+/\//; # get rid of duplicate /'s
#		$oldkey =~ s/\/$//; # remove any trailing /'s
#		
#		$c->{'tsm'}{'policy'}{'path'}{$newkey} = delete $c->{'tsm'}{'policy'}{'path'}{$oldkey};
#	}
	
	return %$c;
}

##
## configuration
##
use Config::General;

# default config
my $defconf = new Config::General(-AutoTrue => 1, -MergeDuplicateOptions => 1, -MergeDuplicateBlocks => 1,
	-ConfigFile => "$AFSBACKUP/etc/default.cfg");
if (!$defconf) {
	print "Failed to read default config file.\n";
	exit 1;
}

# allow config file override from command line
my $configfile;
if (defined $opt{'config'} and $opt{'config'} ne '') {
	$configfile = $opt{'config'};
} else {
	$configfile = "$AFSBACKUP/etc/hosts/$shorthostname/config.cfg";
}
my $conf = new Config::General(-AutoTrue => 1, -DefaultConfig => \$defconf, -MergeDuplicateOptions => 1, -MergeDuplicateBlocks => 1, 
	-ConfigFile => $configfile);
if (!$conf) {
	print "Failed to read config file.\n";
	exit 1;
}

my %c = $conf->getall;
%c = process_config(%c);

if (!$c{'quiet'}) {
	print "= afs-backup.pl =\n\n";
}


if ($c{'verbose'}) {
	print "afsbackup = $AFSBACKUP\n";
	print "hostname = $hostname\n";
	use Data::Dumper;
	print "\n== Configuration ==\n";
	print Dumper(\%c);
}

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
$vdb->fetch_mounts();
my %mounts_by_path = $vdb->get_mounts_by_path();
my %mounts_by_volume = $vdb->get_mounts_by_vol();

if (keys(%mounts_by_path) <= 0 or keys(%mounts_by_volume) <= 0) {
	print "No mounts found! This is bad.\n";
	exit 1;
}
if ($c{'verbose'}) {
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

my $exit = 0;
# switch over $mode
if ($opt{'mode'} eq 'tsm') {
	print "\nRequested mode tsm\n";
	$exit = mode_tsm();
} elsif ($opt{'mode'} eq 'vosbackup') {
	print "\nRequested mode vosbackup\n";
	$exit = mode_vosbackup();
} else {
	print "\nInvalid mode: $opt{'mode'}\n\n";
	exit 1;
}

if ($c{'timing'}) {
	printf "Execution time: %s s\n", time - $total_starttime;
}

print "$opt{'mode'} returned $exit\n";
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
	foreach my $volume (sort keys %in) {
		if ($in{$volume} > 0) {
			$return{$volume} = 1;
		} elsif ($c{'verbose'}) {
			print "exclude_matched() Explicitly excluding volume $volume\n";
		}
	}
	return %return;
}
	
# return match_by_* type hash with volumes removed based on lastbackup times
sub exclude_lastbackup(\%$) {
	my ($in, $mode) = @_;
	my ($volume_to_check, %return);
	foreach my $volume (sort keys %$in ) {
		if ($c{'tsm'}{'dotbackup'}) {
			$volume_to_check = "$volume.backup";
		} else {
			$volume_to_check = $volume;
		}
		# not checking the .backup volume means we share lastupdate times between foo and foo.backup
		# but we could lose data when switching to use .backup if the volume is updated between the time we
		# backed up the .backup and the time we switched
		if (get_vol_updatedate($volume_to_check) > get_lastbackup($mode, $volume)) {
			$return{$volume} = 1;
		} elsif ($c{'verbose'}) {
			print "exclude_lastbackup() Skipping volume $volume ($volume_to_check)\n";
		}
	}
	return %return;
}

##
## miscellaneous functions
##

sub cmd($) {
	my @command = @_;
	my (@output, $status, $starttime, $delta_t);

	if ($c{'pretend'}) {
		printf "[cmd] %s\n", @command;
		return 1;
	} elsif ($c{'timing'}) {
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
			if (! $c{'quiet'}) {
				print "$_";
			}
			push (@output, $_);
		}
		waitpid ($pid, 0);
		$status = $?;
		close OUT;
		if ($c{'timing'}) {
			$delta_t = time - $starttime;
			if ($delta_t > 5) {
				printf "(%s s)\n", $delta_t;
			}
		}
	}
	return ($status == 0);
}

sub get_lastbackup($$) {
	my ($mode, $volume) = @_;
	my $file = $AFSBACKUP . '/var/lastbackup/' . $volume . '.' . $mode;
	if ( -e "$file") {
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

sub set_lastbackup($$) {
	if (!$c{'pretend'}) {
		my ($mode, $volume) = @_;
		my $file = $AFSBACKUP . '/var/lastbackup/' . $volume . '.' . $mode;
		open (HANDLE, ">$file") or print "cannot open file $file: $!\n";
		print HANDLE time;
		close (HANDLE);
	}
}

sub get_vol_updatedate($) {
	my ($volume) = @_;
	foreach (`vos exam -format $volume 2>&1`) {
		if (m/updateDate\s+(.+?)\s+.*$/) {
			return $1;
		}
	}
	return 0;
}

##
## TSM mode
##
sub mode_tsm {
	# start writing dsm.sys
	my $dsmsys = "$AFSBACKUP/var/tmp/dsm.sys.$shorthostname";
	if ( -e $dsmsys) {
		cmd("rm -f $dsmsys");
	}
	if ( -e "$AFSBACKUP/etc/common/dsm.sys.head") {
		cmd("cp $AFSBACKUP/etc/common/dsm.sys.head $dsmsys");
	}
	if ( ! -e "$AFSBACKUP/etc/hosts/$shorthostname/dsm.sys.head") {
		print "$AFSBACKUP/etc/hosts/$shorthostname/dsm.sys.head does not exist!\n";
		exit 1;
	}
	cmd("cat $AFSBACKUP/etc/hosts/$shorthostname/dsm.sys.head >> $dsmsys");

	if ( -e "$dsmsys" or $c{'pretend'}) {
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
			if ($c{'dotbackup'}) {
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
	
	my $backup_matched_num = keys %backup_matched;
	# remove volumes that were excluded (value < 0)
	%backup_matched = exclude_matched(%backup_matched);
	if ($c{'lastbackup'}) {
		%backup_matched = exclude_lastbackup(%backup_matched, 'tsm');
	}

	# get %backup_paths based on %backup_volumes, and the shortest normal path
	my (%backup_paths);
	foreach my $volume (keys %backup_matched) {
		foreach my $path (keys %{$mounts_by_volume{$volume}{'paths'}}) {
#			next if $mounts_by_volume{$volume}{'paths'}{$path} ne '#'; # skip explicit RW mounts
			if (defined($backup_paths{$volume})) {
				if (length($path) < length($backup_paths{$volume})) {
					$backup_paths{$volume} = $path;
				}
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
			

	print "\n=== Paths/mountpoints to backup ===\n";
	print "PATH | VOLUME | MGMTCLASS\n";
	foreach my $volume (sort keys %backup_paths) {
		printf "%s | %s | %s\n", $backup_paths{$volume}, $volume, $policy_by_volume{$volume};
	}
	print "TOTAL: " . keys(%backup_paths) . " volumes selected out of " . $backup_matched_num . " candidate volumes. \n";
	print "There are " . keys(%mounts_by_volume) . " volumes total mounted within the cell.\n\n";

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
	cmd("cat $AFSBACKUP/etc/common/exclude.list >> $dsmsys");
	cmd("cat $AFSBACKUP/etc/hosts/$shorthostname/exclude.list >> $dsmsys");
	close (DSMSYS); # close dsm.sys.$tsmnode

	if (! cmd("cp $dsmsys /opt/tivoli/tsm/client/ba/bin/dsm.sys")) {
		print "Could not copy $dsmsys to /opt/tivoli/tsm/client/ba/bin/dsm.sys !\n";
		return 1;
	}
	
	# make sure a .backup volume exists for every volume
	# vos backup if not
	# then mount each volume
	if ($c{'tsm'}{'dotbackup'}) {
		if (!$c{'quiet'}) {
			print "\n=== Creating .backup volumes if needed ===\n";
		} 
		foreach my $v (sort keys %backup_paths) {
			if (!$c{'quiet'}) {
				print "Checking for BK volume for $v ...\n";
			}
			if (! cmd("vos exam $v.backup >/dev/null 2>&1")) {
				if ($c{'verbose'}) {
					print "No backup volume for $v. Will attempt to create.\n";
					cmd("$c{'commands'}{'vosbackup'} $v");
				}
			}
		}
	}

	if ($c{'tsm'}{'dotbackup'}) {
		cmd("fs rmm $c{'tsm'}{'tmp-mount-path'}/root.cell >/dev/null 2>&1");
		cmd("fs mkm $c{'tsm'}{'tmp-mount-path'}/root.cell root.cell.backup");
	}

	# dump vldb
	if ($c{'tsm'}{'dumpvldb'}) {
		print "\n=== Dumping VLDB metadata to $AFSBACKUP/var/vldb/vldb.date ===\n";
		cmd("dumpvldb.sh $AFSBACKUP/var/vldb/vldb.`date +%Y%m%d-%H%M%S`");
	}

	# dump acls
	if ($c{'tsm'}{'dumpacls'}) {
		print "\n=== Dumping ACLs ===\n";
		foreach my $v (sort keys %backup_paths) {
			printf "[acl] %s (%s)\n", $backup_paths{$v}, $v;
			my $path;
			if ($c{'tsm'}{'dotbackup'}) {
				$path = $c{'tsm'}{'tmp-mount-path'} . '/' . $v;
				cmd("fs rmm $path >/dev/null 2>&1");
				cmd("fs mkm $path $v.backup");
			} else {
				$path = $backup_paths{$v};
			}
			cmd("dumpacls.pl $path > $AFSBACKUP/var/acl/$v 2>/dev/null");
			if ($c{'tsm'}{'dotbackup'}) {
				cmd("fs rmm $path >/dev/null 2>&1");
			}
		}
	}

	# run dsmc incremental
	print "\n=== Running dsmc incremental ===\n";
	cmd("mv $AFSBACKUP/var/log/dsmc.log.$shorthostname $AFSBACKUP/var/log/dsmc.log.$shorthostname.last ; 
		mv $AFSBACKUP/var/log/dsmc.error.$shorthostname $AFSBACKUP/var/log/dsmc.error.$shorthostname.last");

	my $snapshotroot='';
	foreach my $v (sort keys %backup_paths) {
		printf "[dsmc] %s (%s)\n", $backup_paths{$v}, $v;
		if ($c{'tsm'}{'dotbackup'}) {
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
			$AFSBACKUP . '/var/log/dsmc.log.' . $shorthostname,
			$AFSBACKUP . '/var/log/dsmc.error.' . $shorthostname);
		if ($c{'tsm'}{'dsmc'}) {
			# dsmc can return weird values, so we don't check the exit status at all
			cmd($command);
			set_lastbackup('tsm', $v);
		} else {
			print "$command\n";
		}
	}

} # END mode_tsm()


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
	
	if (!$c{'quiet'}) {
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
		print "$c{'commands'}{'vosbackup'} $volume\n";
		if (!cmd("$c{'commands'}{'vosbackup'} $volume")) {
			print "\tfailed\n";
			$return = 1;
		} else {
			set_lastbackup('vosbackup', $volume);
		}
	}
	return $return;
} # END sub mode_vosbackup()




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
