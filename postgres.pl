#!/usr/bin/perl -w
use Getopt::Long;
use File::Basename;
use Data::Dumper;
use Digest::MD5 qw(md5);
use File::Copy;
use Carp;

use strict;

our $parallelism;
our $work_dir;
our $git_local_repo;
our $doxy_file;
our $CC;
our $CFLAGS;
our $CXXFLAGS;
our $min_version='9.2';
our $show_commit=0;
our $make_check=1;
our $checkpoint_segments=32;
our $min_wal_size="512MB";
our $max_wal_size="1500MB";
our $CONFIGOPTS; # Do not mistake for $configopt (the command line that will be
                 # passed to configure
our $LD_LIBRARY_PATH;

our $help=0;
our $tar_mode=0; # Should we compile from git or a tar ? (useful when the flex/bison
                 # files are no longer compatible with the flex/bison on the machine)

my $conf_file;

my $version;
my $clusterid;
my $mode;
my $configopt='';

# Has used to determine what version should be used for a specific version
# of PG
my %postgis_version=(
    '8.2' => {  'geos'   => 'geos-3.3.9',
                'proj'   =>'proj-4.5.0',
                'gdal'   =>'gdal-1.9.2',
                'postgis'=>'postgis-1.3.2',
    },
    '9.1' => {  'geos'   => 'geos-3.3.9',
                'proj'   =>'proj-4.8.0',
                'jsonc'  =>'json-c-0.9',
                'gdal'   =>'gdal-1.9.2',
                'postgis'=>'postgis-2.0.4',
    },
    '9.2' => {  'geos'   => 'geos-3.3.9',
                'proj'   =>'proj-4.8.0',
                'jsonc'  =>'json-c-0.9',
                'gdal'   =>'gdal-1.9.2',
                'postgis'=>'postgis-2.0.4',
    },
    '9.3' => {  'geos'   => 'geos-3.4.2',
                'proj'   =>'proj-4.9.1',
                'jsonc'  =>'json-c-0.12',
                'gdal'   =>'gdal-1.11.2',
                'postgis'=>'postgis-2.1.0',
    },
    '9.4' => {  'geos'   => 'geos-3.4.2',
                'proj'   =>'proj-4.9.1',
                'jsonc'  =>'json-c-0.12-20140410',
                'gdal'   =>'gdal-2.0.0',
                'postgis'=>'postgis-2.1.7',
    },
    '9.5' => {  'geos'   => 'geos-20160918',
                'proj'   =>'proj-4.9.1',
                'jsonc'  =>'json-c-0.12-20140410',
                'gdal'   =>'gdal-2.0.0',
                'postgis'=>'postgis-2.2.2',
    },
    '9.6' => {  'geos'   => 'geos-20160918',
                'proj'   =>'proj-4.9.1',
                'jsonc'  =>'json-c-0.12-20140410',
                'gdal'   =>'gdal-2.0.0',
                'postgis'=>'postgis-2.2.2',
    },
    'HEAD.' => {'geos'   => 'geos-3.4.2',
                'proj'   =>'proj-4.9.1',
                'jsonc'  =>'json-c-0.12-20140410',
                'gdal'   =>'gdal-2.0.1',
                'postgis'=>'postgis-2.1.8',
    },
);

# New configopts per version
my %new_configopts_per_version=(
        '11' => ['--with-llvm'],
        'dev' => ['--with-llvm']);

# No idea what version it could be, but lets's do this right now
my %deprecated_configopts_per_version=(
        );

# The following has is used to get a correspondance between a regex on a filename
# to be downloaded and its URL. The anonymous blocks are intended to be short
# If this gets nasty, we'll return a candidate list of URLs and test them,
# but this method has been working for a while.
my %tar_to_url=(
    'json-c-\d+\.\d+-\d+\.tar\.gz' => sub { return ("https://github.com/json-c/json-c/archive/" . $_[0])},
    'json-c-\d+\.\d+\.tar\.gz' => sub { return ("https://github.com/downloads/json-c/json-c/" . $_[0])},
    'gdal' => sub { $_[0] =~ /gdal-(.+?)\.tar\.gz/;
                    my $version=$1;
                    if (compare_versions($version,'1.10.2')>=0) # The file is in a subdirectory
                    {
                       return ("http://download.osgeo.org/gdal/" . $version . '/' . $_[0] )
                    }
                    return ("http://download.osgeo.org/gdal/${_[0]}")
                  },
    'proj' => sub { return ("http://download.osgeo.org/proj/" . $_[0])},
    'geos' => sub { return ("http://download.osgeo.org/geos/" . $_[0])},
    'postgis' => sub { return ("http://download.osgeo.org/postgis/source/" . $_[0])},
    'postgres' => sub { $_[0] =~ /postgresql-(.+?)\.tar\.bz2/;
                    my $version=$1;
                    return ("https://ftp.postgresql.org/pub/source/v" . $version . "/postgresql-" . $version. ".tar.bz2")
                  },
);


sub major_minor
{
    my ($version) = @_;
    return ("HEAD", "", "") if $version eq "dev";

    # This is for the new numbering since pg 10
    $version =~ /^(\d+).*/
            or croak "Weird version $version in major_minor\n";
    my $major1=$1;

    # Lets calculate the 3 version numbers
    # If we have been given 3 numbers, no point in going any further
    if ($version =~ /^(\d+)\.(\d+)\.(.+)$/)
    {
        return ($1,$2,$3);
    }
    if ($major1 < 10)
    {
        # This has existed for very old versions (such as 6.2)
        if ($version =~ /^(\d+)\.(\d+)$/)
        {
            return ($1,$2,0);
        }
        else
        {
            croak "Weird version $version in major_minor\n";
        }
    }
    else
    {
        $version =~ /^(\d+)\.(\d+|dev)$/
            or croak "Weird version $version in major_minor\n";
        return ($1,$2);
    }
}

# Transform a minor number into a numeric "score", to be used in comparison
# functions
# dev>rc>beta>alpha.
# To make the comparison simple,
# alpha=0, beta=100, rc=200, final=300, dev (head of the branch)=400.
# We add them to the version number found.
sub calculate_minor
{
    my ($minor)=@_;
    my $score;

    if ($minor =~ /^(alpha|beta|rc)(\d+)$/)
    {
        if ($1 eq 'alpha')
        {
            $score=0+$2;
        }
        elsif ($1 eq 'beta')
        {
            $score=100+$2;
        }
        elsif ($1 eq 'rc')
        {
            $score=200+$2;
        }
    }
    elsif ($minor =~ /^(\d+)$/)
    {
        $score=300+$1;
    }
    elsif ($minor =~ /^dev|stable$/)
    {
            $score=400;
    }
    else
    {
        croak("Minor not expected\n");
    }

    return $score;
}

# Behaves like cmp and <=>, but with two PG versions
# Accepts formats such as 9.3, 9.3.9, 9.3.beta1
sub compare_versions
{
    my ($version1, $version2) = @_;

    # early exits:
    return 1 if ($version1 eq 'dev' or $version1 eq 'review');
    return -1 if ($version2 eq 'dev' or $version2 eq 'review');

    # Lets start by comparing majors
    my ($major11, $major21, $minor1) = major_minor($version1);
    my ($major12, $major22, $minor2) = major_minor($version2);

    if ($major11<=>$major12)
    {
        return $major11<=>$major12;
    }

    if ($major21<=>$major22)
    {
        return $major21<=>$major22;
    }

    # Now for the minor
    # If the minors are just numbers, that's easy. Else we have to compare
    # dev, rc, beta,alpha...
    my $score1=calculate_minor($minor1);
    my $score2=calculate_minor($minor2);
    return $score1<=>$score2;
}

# This function adds configuration options for special cases (old versions
# with compile problems). It's there for overriding the environment (CC, CFLAGS...)
# For instance there are now problems with pre-9 version if -O is not 0...
sub special_case_compile
{
    my ($version)=@_;
    if (compare_versions($version,'9.0.0') < 0)
    {
        $ENV{CFLAGS}.=' -O0';
    }
    return $configopt;
}

# Convert a version into a git tag
sub version_to_REL
{
    my ($version)=@_;
    my $rel=$version;
    my $tag_header;

    if  ($version =~ /^dev$|^review$/)
    {
        return 'master';
    }

    # We only have versions starting with numbers left
    $version =~ /^(\d+)/ or croak "Weird version $version";

    # The naming convention has changed with 10+ versions
    if ($1 < 10)
    {
        $tag_header='REL'
    }
    else
    {
        $tag_header='REL_'
    }

    if ($version =~ /^([0-9.]+)\.(dev|stable)$/)
    {
        # Special case: no tag, we need to fetch something like origin/REL9_0_STABLE
        $rel=~ s/\./_/g;
        $rel=~ s/^/origin\/$tag_header/;
        $rel=~ s/_dev$/_STABLE/;
        $rel=~ s/_stable$/_STABLE/;
        return $rel;
    }
    elsif ($version =~ /^([0-9.]+)\.(alpha|beta|rc)(\d+)$/)
    {
        # Version <10
        $rel=~ s/\./_/g;
        $rel=~ s/beta/BETA/g;
        $rel=~ s/alpha/ALPHA/g;
        $rel=~ s/rc/RC/g;
        $rel=$tag_header . $rel;
        return $rel;
    }
    else
    {
        $rel=~ s/\./_/g;
        $rel=$tag_header . $rel;
        return $rel;
    }
}

# Try to avoid having confess all over the code
sub system_or_confess
{
    my ($command,$mute)=@_;
    $mute=0 unless defined($mute);
    my $fh;
    my @return_value;
    open($fh,'-|',$command) or confess "Cannot run $command: $!";
    while (my $line=<$fh>)
    {
        push @return_value,($line);
        unless ($mute)
        {
            print $line;
        }
    }
    close ($fh);
    if ($?>>8 != 0)
    {
        confess "Command $command failed.\n";
    }
    return \@return_value; # By reference, this may be quite big
}

# Get the destination dir for a compiled version
sub dest_dir
{
    my ($version)=@_;
    my ($major1,$major2,$minor) = major_minor($version);
    my $versiondir;

    if ($major1 eq "HEAD"){
        $versiondir="dev";
    } elsif ($major1 < 10){
        $versiondir="$major1.$major2.$minor";
    } else {
        $versiondir="$major1.$major2";
    }

    return("${work_dir}/postgresql-${versiondir}");
}

# Get the PGDATA for a version
sub get_pgdata
{
    my ($dir, $clusterid) = @_;
    my $id = '';
    $id = $clusterid if $clusterid ne 0;
    return "$dir/data$id";
}

# Calculate a PGPORT. We use the first 15 bits of the md5 of the version to get a port.
# Conflict probability should stay very low unless people start running dozens of instances
sub get_pgport
{
    my ($version, $clusterid) = @_;
    return unpack('n',pack('B15','0'.substr(unpack('B128',md5($version.$clusterid)),0,15))) + 1025;
}

# Set environment variables from setup
sub setenv
{
    # Default compilation options
    if (not defined $CC)
    {
        undef $ENV{CC};
    }
    else
    {
        $ENV{CC}=$CC;
    }
    if (not defined $CFLAGS)
    {
        undef $ENV{CFLAGS};
    }
    else
    {
        $ENV{CFLAGS}=$CFLAGS;
    }
}

# Remove configopts that are not present in this version
sub cleanup_configopts
{
        my ($config,$version)=@_;
        foreach my $paramversion(keys (%new_configopts_per_version))
        {
                if (compare_versions($version,$paramversion)==-1)
                {
                        # This version is older than paramversion, so we remove these options
                        my @to_remove=@{$new_configopts_per_version{$paramversion}};
                        foreach my $param (@to_remove)
                        {
                                print "Removing incompatible param $param from configure options\n";
                                $config=~ s/$param//;
                        }
                }
        }
        foreach my $paramversion(keys (%deprecated_configopts_per_version))
        {
                if (compare_versions($version,$paramversion)==1)
                {
                        # This version is newer than paramversion, so we remove these options
                        my @to_remove=@{$deprecated_configopts_per_version{$paramversion}};
                        foreach my $param (@to_remove)
                        {
                                print "Removing incompatible param $param from configure options\n";
                                $config=~ s/$param//;
                        }
                }
        }
        return $config;
}

# Build a PostgreSQL version
sub build
{
    my ($tobuild)=@_;
    my $dest=dest_dir($tobuild);
    # Build the configure command line
    $configopt="--prefix=$dest $CONFIGOPTS";
    my $tag=version_to_REL($tobuild);
    my $check = "";
    # We keep data, just remove binaries
    clean($tobuild, 0);
    mkdir ("${dest}");
    # The directory is probably still there if this is not the first build
    # Let's just check it is there
    confess "Cannot mkdir ${dest} : $!\n" if (not -d ${dest});
    if (not $tar_mode)
    {
        chdir "${dest}" or confess "Cannot chdir ${dest} : $!\n";
        mkdir ("src") or confess "Cannot mkdir src : $!\n";
        mkdir ("src/.git") or confess "Cannot mkdir src/.git : $!\n";
        system_or_confess("git clone --mirror ${git_local_repo} src/.git");
        chdir "src" or confess "Cannot chdir src : $!\n";
        system_or_confess("git config --bool core.bare false");
        system_or_confess("git reset --hard");
        system_or_confess("git checkout $tag");
        # If we've been asked, let's display the commit information
        if ($show_commit)
        {
            my $commit = system_or_confess("git show HEAD --abbrev-commit --stat|head -n1|cut -d' ' -f2");
            $configopt .= " --with-extra-version=@" . @{$commit}[0];
        }
        system_or_confess("rm -rf .git"); # Get rid of git data, we don't need it now
    }
    else
    {
        # Build from tar
        my $tar_postgres="postgresql-" . $tobuild . ".tar.bz2";
        try_download($tar_postgres,"postgres_versions");
        mkdir ("$dest/src");
        system_or_confess("nice -19 tar -xvf $work_dir/postgres_versions/$tar_postgres -C $dest/src/  --strip-components=1");
        chdir "${dest}/src" or confess "Cannot chdir ${dest}/src : $!\n";
    }
    special_case_compile($tobuild);
    print "./configure $configopt\n";

    # Cleanup the CONFIGOPTS depending on the version
    $configopt=cleanup_configopts($configopt,$version);

    system_or_confess("./configure $configopt");
    if ($make_check)
    {
        $check = " && make check ";
    }
    system_or_confess("nice -19 make -j${parallelism} $check && make install && cd contrib && make -j3 && make install");
}

# Generic build function. Mostly for postgis and its dependencies
sub build_something
{
    my ($tar,@commands)=@_;
    # Some files may not have been downloaded. Try to get them
    try_download($tar,"postgis") if ((! -f $tar) or (-z $tar));
    print "Décompression de $tar\n";
    my $return_value_tar=system_or_confess("tar xvf $tar",1); # 1 = mute, we don't care seeing the tar on screen
    # We keep the first line to know where this tar has decompressed. json-c is not typical on this
    $return_value_tar->[0] =~ /^(.*)\// or confess "Cannot find subdirecroty from " . $return_value_tar->[0];
    my $dir = $1;
    chdir ($dir);
    foreach my $command(@commands)
    {
        system_or_confess($command);
    }
    chdir ('..');
    system_or_confess("rm -rf $dir");
}

# Find the file
# We'll use regexps to guess what we are trying to download :)
sub try_download
{
    my ($file,$dest)=@_;
    # Find the entry from %tar_to_url matching (regexp)
    my $url;
    my $found=0;
    while (my ($regexp,$subref)=each %tar_to_url)
    {
       next unless $file =~ /$regexp/;
       $found=1;
       $url=&{$subref}($file);
    }
    confess "Cannof find ${file}'s URL" unless ($found);
    mkdir("$work_dir/$dest");
    print "Downloading $file : wget -c $url -O $work_dir/$dest/$file\n";
    system("wget -c $url -O $work_dir/$dest/$file");
    unless ($? >>8 == 0)
    {
        move ("$work_dir/$dest/$file","$work_dir/$dest/$file.failed");
        confess "Cannot download $file";
    }
}

# Build doxygen. From a Doxyfile which must have been set in the configuration
sub doxy
{
    my ($version)=@_;
    my $dest=dest_dir($version);
    # Creation du fichier doxygen
    my $src_doxy="${dest}/src/";
    my $dest_doxy="${dest}/doxygen/";
    mkdir("${dest_doxy}");
    open DOXY_IN,$doxy_file or confess "Cannot find the doxygen <$doxy_file> configuration file: $!";
    open DOXY_OUT,"> ${dest_doxy}/Doxyfile" or confess "Cannot write to ${dest_doxy}/Doxyfile: $!";
    while (my $line=<DOXY_IN>)
    {
        $line =~ s/\$\$OUT_DIRECTORY\$\$/${dest_doxy}/;
        $line =~ s/\$\$IN_DIRECTORY\$\$/${src_doxy}/;
        $line =~ s/\$\$VERSION\$\$/$version/;
        print DOXY_OUT $line;
    }
    close DOXY_OUT;
    close DOXY_IN;
    # We can produce the doxygen
    system("doxygen ${dest_doxy}/Doxyfile");
    # Now, as the amount of html resulting files is huge, lets create an index.html file
    # at the root directory, redirecting
    open DOXY_OUT,"> ${dest_doxy}/index.html" or confess "impossible de créer ${dest_doxy}/index.html: $!";
    print DOXY_OUT << 'THEEND';
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="refresh" content="0; url=html/index.html" />
</head>
<body>
</body>
</html>

THEEND
    close DOXY_OUT;
}

# Build Postgis
sub build_postgis
{
    my ($tobuild)=@_;
    # Let's check the LD_LIBRARY_PATH is ok before going somewhere
    # If someone has already set proj in the LD_LIBRARY_PATH, too bad for him
    unless ((defined $ENV{LD_LIBRARY_PATH} and $ENV{LD_LIBRARY_PATH} =~ /proj/) or defined $LD_LIBRARY_PATH)
    {
        confess "The LD_LIBRARY_PATH  must be set. Start this scrip in env mode and import the variables\n";
    }
    my ($major1,$major2)=major_minor($tobuild);
    my $major=$major1 . '.' . $major2;
    unless (defined $postgis_version{$major})
    {
        confess "Cannot determine the correct Postgis versions to be used with postgres $major";
    }
    no warnings; # Lots of the following values will be undef
    my $refversion=$postgis_version{$major};
    my $geos=$refversion->{'geos'};
    my $proj=$refversion->{'proj'};
    my $jsonc=$refversion->{'jsonc'};
    my $gdal=$refversion->{'gdal'};
    my $postgis=$refversion->{'postgis'};
    my $postgisdir = "$work_dir/postgis";

    if (not -d $postgisdir)
    {
        mkdir($postgisdir);
    }
    chdir($postgisdir) or confess "Cannot chdir into $postgisdir\n";
    system("rm -rf $geos $proj $postgis $jsonc $gdal");

    use warnings;

    my $dest=dest_dir($tobuild);

    my $postgis_options='';
    # We will update PATH during the compilation: old Postgis versions didn't accept paths in the configure
    if (defined $geos)
    {
        build_something("${geos}.tar.bz2","./configure --prefix=${dest}/geos","make -j $parallelism","make install");
        $postgis_options.=" --with-geosconfig=${dest}/geos/bin/geos-config";
        $ENV{PATH}="${dest}/geos/bin/" . ':' . $ENV{PATH};
    }
    if (defined $proj)
    {
        build_something("${proj}.tar.gz","./configure --prefix=${dest}/proj","make -j $parallelism","make install");
        $postgis_options.=" --with-projdir=${dest}/proj";
        $ENV{PATH}="${dest}/proj/bin/" . ':' . $ENV{PATH};
    }
    if (defined $jsonc)
    {
        build_something("${jsonc}.tar.gz","./configure --prefix=${dest}/jsonc","make","make install");
        $postgis_options.=" --with-jsondir=${dest}/jsonc";
    }
    if (defined $gdal)
    {
        build_something("${gdal}.tar.gz","./configure --prefix=${dest}/gdal","make -j $parallelism","make install");
        $postgis_options.=" --with-gdalconfig=${dest}/gdal/bin/gdal-config";
    }
    build_something("${postgis}.tar.gz","./configure $postgis_options --prefix=${dest}/postgis","make -j $parallelism","make","make install");
    print "Postgis compilation OK\n";

}

# List all installed and running versions
sub list
{
    my @versions = <$work_dir/postgresql-*/>;

    print "  Instance     Port Standby?\n";
    print "-----------------------------\n";

    @versions = grep {$_ !~ /^$git_local_repo\/?$/} @versions;
    for(@versions){
        s/.*postgresql-(.*)\/$/$1/;
    }

    foreach my $ver (sort {compare_versions($a, $b)} @versions)
    {
        my @instances = <$work_dir/postgresql-$ver/data*>;
        my $nb = 0;

        foreach my $inst (sort @instances)
        {
            $inst =~ /data(\d*)$/;
            my $id = $1;
            $id = 0 if ($id eq '');
            my $port = get_pgport($ver, $id);
            if (-f "$inst/postmaster.pid")
            {
                printf "*"
            }
            else {
                printf " "
            }

            printf " ";
            printf "%-12s", "$ver/$id";
            printf "%5s ", get_pgport($ver, $id);

            if (-f "$inst/recovery.conf")
            {
                print "Yes";
            }
            else
            {
                print "No";
            }
            print "\n";
            $nb++;
        }
        if ($nb == 0)
        {
            printf "  %-16s", "$ver";
            printf "%-5s", "-";
            print "\n";
        }
    }
}

# List all available versions in the git repository
sub list_avail
{
    chdir ("$git_local_repo") or confess "There is no $git_local_repo directory\nClone one with git clone git://git.postgresql.org/git/postgresql.git";
    my @versions=`git tag`;
    my @return_value;

    foreach my $version(@versions)
    {
        chomp $version;
        next unless ($version =~ /^REL/);
        next if ($version =~ /RC|BETA|ALPHA/);
        $version =~ s/^REL//g;
        $version =~ s/_/./g;
        # Since version 10, this is REL_10_1 and not REL9_6_5, so we get an initial dot
        # Let's remove it
        $version =~ s/^\.//;
        push @return_value, ($version)
    }
    return(\@return_value);
}

# List all latest versions per branch
sub ls_latest
{
    my $refversions=list_avail();
    my $prevversion='';
    my $prevmajor='';
    my @return_value;
    foreach my $version(sort {compare_versions($a,$b) } @$refversions)
    {
        my ($major1,$major2)=major_minor($version);
        my $major="$major1.$major2";
        if ($prevmajor and ($major ne $prevmajor))
        {
            push @return_value, ($prevversion);
        }
        $prevmajor=$major;
        $prevversion=$version;
    }
    push @return_value, ($prevversion);
    return(\@return_value);
}

# Build latest versions, and remove old versions (keeping data)
sub rebuild_latest
{
    my @latest=@{ls_latest()};
    foreach my $version(@latest)
    {
        my $already_compiled=0;
        my ($major1,$major2)=major_minor($version);
        my @olddirs=<$work_dir/postgresql-${major1}.${major2}*>;
        # olddirs will look like /home/marc/postgres/postgresql-9.3.0
        foreach my $olddir(@olddirs)
        {
            next if ($olddir =~ /dev$/ or $olddir =~ /review$/);
            next unless (-d $olddir);

            $olddir=~ /(\d+\.\d+\.\d+)$/ or confess "Weird directory name: $olddir\n";
            my $oldversion=$1;

            if (compare_versions($oldversion,$version)==0)
            {
                print "The $version is already compiled.\n";
                $already_compiled=1;
            }
            else
            {
                print "Removal of the obsolet $oldversion version. (data directory kept)\n";
                clean($oldversion, 0);
            }
        }

        # Only versions over $min_version (to not compile very old versions)
        unless ($already_compiled or compare_versions($version,$min_version)==-1)
        {
            print "Building $version.\n";
            build($version);
        }
    }
}

# Remove a version (and optionnaly the data directory)
sub clean
{
    my ($version, $remove_data)=@_;
    $remove_data = 0 if not defined $remove_data;
    my $dest=dest_dir($version);
    croak unless (defined $dest and $dest ne '');
    stop_all_clusters($version,'immediate'); # If this fails, too bad
    if ($remove_data) {
        # we remove everything, including data
        system_or_confess("rm -rf $dest");
    } else {
        # if the directory doesn't exist, no need to go further
        return if (not -d $dest);
        # we keep data
        system_or_confess("find $dest -mindepth 1 -maxdepth 1 -type d -path '*data*' -prune -o -exec rm -rf {} \\;");
        # If the directory is empty, let's revome it (it will fail if not)
        rmdir($dest);
    }
}

# does a cluster exist ?
sub cluster_exists
{
    my ($version, $clusterid) = @_;
    my $dir = dest_dir($version);
    my $pgdata = get_pgdata($dir, $clusterid);

    return 0 if (not -d $pgdata);
    return 1;
}
# This function builds a new standby server from an existing cluster.
# A recovery.conf file will be automatically generated with a SR connection.
# Les version 8.4- ne sont pas supportées.
sub add_standby
{
    my ($version, $clusterid) = @_;

    if (compare_versions($version, '9.0') == -1)
    {
    confess "Only Streaming Replication is supported";
    }

    confess "The $version/$clusterid cluster doesn't exist !" if not cluster_exists($version, $clusterid);

    my $newclusterid = $clusterid;
    my $ok = 0;
    while (not $ok)
    {
        $newclusterid++;
        $ok = 1 if (not cluster_exists($version, $newclusterid));
    }
    print "The standby will be $version/$newclusterid\n";

    # Stop the source cluster
    stop_one_cluster($version,$clusterid);

    print "Copying data...\n";
    my $dir = dest_dir($version);
    my $pgdata_src = get_pgdata($dir,$clusterid);
    my $pgdata_dst = get_pgdata($dir,$newclusterid);
    my $pgport = get_pgport($version, $clusterid);
    system_or_confess("cp -R $pgdata_src $pgdata_dst");
    if (compare_versions($version, '10.0') > 0) {
        system_or_confess("find $pgdata_dst/pg_wal/ -type f -delete");
    } else {
        system_or_confess("find $pgdata_dst/pg_xlog/ -type f -delete");
    }

    print "Produce a recovery.conf\n";
    my $recovery = "$pgdata_dst/recovery.conf";
    open RECOVERY_CONF, "> $recovery" or confess "Cannot create $recovery: $!";
    print RECOVERY_CONF "standby_mode = 'on'\n";
    print RECOVERY_CONF "primary_conninfo = 'host=127.0.0.1 port=$pgport application_name=\"$version/$newclusterid\"'\n";
    close RECOVERY_CONF;

    print "$version/$newclusterid standby ready !"
}

# This displays the shell commands to run
# It cannot change the calling shell's environment by itsel, so it has to
# be run from shell with backticks (or equivalent)
sub env
{
    unless ($version)
    {
        print STDERR "I need a version number\n";
        usage();
    }
    if (not defined $clusterid)
    {
        print STDERR "I need a cluster number\n";
        usage();
    }

    # We return an error if the version number is not recognized
    unless ($version =~ /^(((\d+)\.(\d+)\.(?:(\d+)|(alpha|beta|rc)(\d+)|(dev))?)|(([0-9][0-9])\.(?:(\d+)|(alpha|beta|rc)(\d+)|(dev|stable))?)|(dev|review))$/)
    #                      ^ 3 digit version number                              ^ 2 digit version number (after 10)                         ^ master
    {
        print STDERR "Cannot understand: <$version>\n";
        usage();
    }

    # We cleanup the path from old versions, just in case
    my $oldpath=$ENV{PATH};
    $oldpath =~ s/${work_dir}.*?\/bin://g;

    my $dir=dest_dir($version);
    my $pgdata=get_pgdata($dir,$clusterid);

    print "export PATH=${dir}/bin:" . $oldpath . "\n";
    print "export PAGER=less\n";
    print "export PGDATA=${pgdata}\n";
    print 'if [[ $PS1 != *"pgversion"* ]]; then' . "\n";
    print '    export PS1="[\$pgversion/\$pgclusterid]$PS1"' . "\n";
    print "fi\n";
    my $ld_library_path;

    # For LD_LIBRARY_PATH: we keep what we have and either add the default
    # value or what the user has put in place in the configuration
    if (defined $LD_LIBRARY_PATH)
    {
        $ld_library_path=$LD_LIBRARY_PATH;
    }
    else
    {
        $ld_library_path="${dir}/proj/lib:${dir}/geos/lib:${dir}/jsonc/lib:${dir}/gdal/lib:${dir}/lib";
    }
    if (defined $ENV{LD_LIBRARY_PATH})
    {
        $ld_library_path.= ':' . $ENV{LD_LIBRARY_PATH}
    }
    print "export LD_LIBRARY_PATH=$ld_library_path\n";


    print "export pgversion=$version\n";
    print "export pgclusterid=$clusterid\n";
    # Produce a port number from a hash of the version and cluster number
    my $pgport=get_pgport($version, $clusterid);
    print "export PGPORT=$pgport\n";
}

# Start the cluster specified with version and clusterid
sub start_one_cluster
{
    my ($version,$clusterid)=@_;
    my $dir=dest_dir($version);
    $ENV{LANG}="en_GB.utf8";
    print "Starting $version/$clusterid...\n";
    unless (-f "$dir/bin/pg_ctl")
    {
        confess "No $dir/bin/pg_ctl binary\n";
    }
    my $pgdata=get_pgdata($dir,$clusterid);
    $ENV{PGDATA}=$pgdata;
    my $args;
    if (compare_versions($version,'8.2')==-1) # Order than 8.2
    {
        $args="-c wal_sync_method=fdatasync -c sort_mem=32000 -c vacuum_mem=32000 -c checkpoint_segments=${checkpoint_segments}";
    }
    elsif (compare_versions($version, "9.5") >= 0)
    {
        $args="-c wal_sync_method=fdatasync -c work_mem=32MB -c maintenance_work_mem=1GB -c min_wal_size=${min_wal_size} -c max_wal_size=${max_wal_size}";
    }
    else
    {
        $args="-c wal_sync_method=fdatasync -c work_mem=32MB -c maintenance_work_mem=1GB -c checkpoint_segments=${checkpoint_segments}";
    }
    if (defined ($ENV{PGSUPARGS}))
    {
        $args=$args . " " . $ENV{PGSUPARGS};
    }
    if (! -d $pgdata)
    { # Création du cluster
        system_or_confess("$dir/bin/initdb");
        system_or_confess("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
        system_or_confess("$dir/bin/createdb"); # To get a database with the dba's name (I'm lazy)
        system_or_confess("openssl req -new -text -out $pgdata/server.req -subj '/C=US/ST=New-York/L=New-York/O=OrgName/OU=IT Department/CN=example.com' -passout pass:toto");
        system_or_confess("openssl rsa -in privkey.pem -out $pgdata/server.key -passin pass:toto");
        unlink ("privkey.pem");
        system_or_confess("openssl req -x509 -in $pgdata/server.req -text -key $pgdata/server.key -out $pgdata/server.crt");
        system_or_confess("chmod og-rwx $pgdata/server.key");
    }
    else
    {
        system_or_confess("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
    }
}

# Start all available clusters on the machine
sub start_all_clusters
{
    my ($version) = @_;
    my $dir=dest_dir($version);

    opendir(my $dh, $dir) || return;
    while (readdir($dh))
    {
        if ($_ =~ /data\d*/)
        {
            my $id = $_;
            $id =~ s/data//;
            $id = 0 if $id eq '';
            start_one_cluster($version,$id);
        }
    }
    closedir $dh;
}

# Stop one cluster
sub stop_one_cluster
{
    my ($version,$clusterid,$mode)=@_;
    if (not defined $mode)
    {
        $mode = 'fast';
    }
    my $dir=dest_dir($version);
    my $pgdata=get_pgdata($dir, $clusterid);
    print "Stopping $version/$clusterid...\n";
    return 1 unless (-e "$pgdata/postmaster.pid"); #pg_ctl doesn't like being told to shut down an already shut down cluster
    $ENV{PGDATA}=$pgdata;
    system("$dir/bin/pg_ctl -w -m $mode stop");
}

# Stop all available clusters
sub stop_all_clusters
{
    my ($version,$mode)=@_;
    my $dir=dest_dir($version);

    opendir(my $dh, $dir) || return;
    while (readdir($dh))
    {
        if ($_ =~ /data\d*/)
        {
            my $id = $_;
            $id =~ s/data//;
            $id = 0 if $id eq '';
            stop_one_cluster($version,$id,$mode);
        }
    }
    closedir $dh;
}

sub git_update
{
    system_or_confess ("cd ${git_local_repo} && git pull");
}

# Configuration is in a .ini like file. It will usually be in /usr/local/etc/postgres_manage.conf,
# ~/.postgres_manage.conf or where the postgres_manage environment variable will tell us, or
# specified on the command line. Priority is command line > environment > default > global

sub load_configuration
{
    # Where is the configuration ?
    unless (defined $conf_file)
    {
        # No command line argument. Let's look at environment...
        if (defined $ENV{postgres_manage})
        {
            $conf_file=$ENV{postgres_manage};
        }
        else
        {
            if (-e ($ENV{HOME} . "/.postgres_manage.conf") )
            {
                $conf_file=($ENV{HOME} . "/.postgres_manage.conf");
            }
            else
            {
                if (-e "/usr/local/etc/postgres_manage.conf")
                {
                    $conf_file="/usr/local/etc/postgres_manage.conf";
                }
            }
        }
    }

    unless (defined $conf_file)
    {
        confess "No configuration file found, neither in command line (-conf), nor in \$postgres_manage,\nnor in " . $ENV{HOME} . "/.postgres_manage.conf, nor in /usr/local/etc/.postgres_manage.conf\n";
    }

    # We look for 4 values: parallelism, work_dir, doxy_file et git_local_repo.
    # We also accept "parallelisme", for compatibility for a previous all-french version :)
    open CONF,$conf_file or confess "Pas pu ouvrir $conf_file:$!\n";
    while (my $line=<CONF>)
    {
        no strict 'refs'; # So we can use symbolic references
        my $line_orig=$line;
        $line=~ s/#.*//; # Comments removal
        $line =~ s/\s*$//; # End of line spaces removal
        $line =~ s/^\s*//; # Start of line spaces removal
        next if ($line =~ /^$/); # Empty lines removal (after comments removal)
        $line =~ s/\s*=\s*/=/; # Spaces around = removal
        # Now the line has been simplified, we can parse it with a simple regex
        $line =~ /(\S+?)=(.*)/ or confess "Cannot understand <$line_orig> in configuration file\n";
        my $param_name=$1; my $param_value=$2;
        $param_name='parallelism' if ($param_name eq 'parallelisme');
        ${$param_name}=$param_value; # Symbolic reference use, for simpler code
    }
    confess "Missing parameters in configuration" unless (defined $parallelism and defined $work_dir and defined $git_local_repo and defined $doxy_file);
    unless (defined $CONFIGOPTS)
    {
        $CONFIGOPTS='--enable-thread-safety --with-openssl --with-libxml --enable-nls --enable-debug --with-ossp-uuid';#Default value
    }
    close CONF;
}

# Usage function
sub usage
{
    print STDERR "$_[0]\n" if ($_[0]);
    print STDERR "$0 -mode MODE [--version x.y.z] [--conf_file path_to_configuration] [--tar_mode]\n";
    print STDERR "MODE can be :\n";
    print STDERR "                env\n";
    print STDERR "                build\n";
    print STDERR "                build_postgis\n";
    print STDERR "                start\n";
    print STDERR "                startall\n";
    print STDERR "                stop\n";
    print STDERR "                stopall\n";
    print STDERR "                clean\n";
    print STDERR "                standby\n";
    print STDERR "                list\n";
    print STDERR "                list_avail\n";
    print STDERR "                list_latest\n";
    print STDERR "                rebuild_latest\n";
    print STDERR "                git_update\n";
    print STDERR "                doxy\n";
    exit 1;
}

GetOptions (
    "version=s"     => \$version,
    "mode=s"        => \$mode,
    "conf_file=s"   => \$conf_file,
    "tar_mode"	    => \$tar_mode,
    "help"          => \$help,
)
or usage("Error in command line arguments\n");

usage() if ($help);

if (not defined $version and (not defined $mode or $mode !~ /list|rebuild_latest|git_update/))
{
    if (defined $ENV{pgversion})
    {
        $version=$ENV{pgversion};
    }
    else
    {
        usage( "Il me faut une version (option -version, ou bien variable d'env pgversion\n");
    }
    if (defined $ENV{pgclusterid})
    {
        $clusterid=$ENV{pgclusterid};
    }
}

# by default, we use cluster 0
$clusterid = '0' if not defined($clusterid);
# If the version number contains a cluster number we get it
if (defined $version and $version =~ /^(.+)\/(\d+)$/)
{
    $version = $1;
    $clusterid = int($2);
}

load_configuration();
setenv();

if (not defined $mode)
{
    usage("We need an execution mode: -mode env for instance...\n");
}
elsif ($mode eq 'env')
{
    env();
}
elsif ($mode eq 'build')
{
    build($version);
}
elsif ($mode eq 'build_postgis')
{
    build_postgis($version);
}
elsif ($mode eq 'start')
{
    start_one_cluster($version, $clusterid);
}
elsif ($mode eq 'startall')
{
    start_all_clusters($version);
}
elsif ($mode eq 'stop')
{
    stop_one_cluster($version, $clusterid);
}
elsif ($mode eq 'stopall')
{
    stop_all_clusters($version);
}
elsif ($mode eq 'clean')
{
    # we also clean data
    clean($version, 1);
}
elsif ($mode eq 'standby')
{
    add_standby($version, $clusterid);
}
elsif ($mode eq 'list')
{
    list();
}
elsif ($mode eq 'list_avail')
{
    print join("\n",@{list_avail()}),"\n";
}
elsif ($mode eq 'list_latest')
{
    print join("\n",@{ls_latest()}),"\n";
}
elsif ($mode eq 'rebuild_latest')
{
    rebuild_latest();
}
elsif ($mode eq 'git_update')
{
    git_update();
}
elsif ($mode eq 'doxy')
{
    doxy($version);
}
else
{
    usage("Unknown mode \"$mode\"\n");
}
