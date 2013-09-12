#!/usr/bin/perl -w
use Getopt::Long;
use File::Basename;


use strict;

my $parallelisme=6;
my $work_dir='/home/marc/postgres';
my $git_local_repo="/home/marc/postgres/postgresql-git";

my $version;
my $mode;
my $configopt;

sub majeur_mineur
{
	my ($version)=@_;
	$version=~ /^(\d+)\.(\d+)(?:\.(.+))?$/ or die "Version bizarre $version dans majeur_mineur\n";
	return ($1,$2,$3);
}

sub calcule_mineur
{
	my ($mineur)=@_;
	my $score;
	if ($mineur =~ /^(alpha|beta|rc)(\d+)$/)
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
	elsif ($mineur =~ /^(\d+)$/)
	{
		$score=300+$1;
	}
	else
	{
		die "Mineur non prévu\n";
	}
	return $score;
}

# Retourne comme cmp et <=> par rapport à 2 versions en paramètre
# Accepte les formats 9.3, 9.3.9, 9.3.beta1
sub compare_versions
{
	my ($version1,$version2)=@_;
	# 9.3 et 9.3.0 c'est pareil. On commence par ça
	if ($version1 =~ /^\d+\.\d+$/)
	{
		$version1=$version1 . ".0";
	}
	if ($version2 =~ /^\d+\.\d+$/)
	{
		$version2=$version2 . ".0";
	}
	# On commence par comparer les majeurs. Ça suffit la plupart du temps
	my ($majeur11,$majeur21,$mineur1)=majeur_mineur($version1);
	my ($majeur12,$majeur22,$mineur2)=majeur_mineur($version2);
	if ($majeur11<=>$majeur12)
	{
		return $majeur11<=>$majeur12;
	}
	if ($majeur21<=>$majeur22)
	{
		return $majeur21<=>$majeur22;
	}
	# Fin du cas simple :)
	# Maintenant, si les mineurs sont juste des numériques, c'est facile. Sinon, il faut prendre en compte que
	# rc>beta>alpha. Pour rendre la comparaison simple, alpha=0, beta=100, rc=200, final=300.
	# On les somme au numéro de version trouvé. C'est ce que fait la fonction calcule_mineur
	my $score1=calcule_mineur($mineur1);
	my $score2=calcule_mineur($mineur2);
	return $score1<=>$score2;
}

# Cette fonction rajoute des options de config pour les cas spéciaux (vieilles versions avec pbs d'options de compil, etc
# Cette fonction utilise la fonction de comparaisons de versions pour faire ses petites affaires.
# On y change les configopt au besoin, l'environnement (CC, CFLAGS…)
# Pour le moment elle est vide :)
sub special_case_compile
{
	my ($version)=@_;
	return $configopt;
}

# Convertir une version en tag git
sub version_to_REL
{
	my ($version)=@_;
	if  ($version =~ /^dev|^review/)
	{
		return 'master';
	}
	my $rel=$version;
	$rel=~ s/\./_/g;
	$rel=~ s/beta/BETA/g;
	$rel=~ s/alpha/ALPHA/g;
	$rel=~ s/rc/RC/g;
	$rel="REL" . $rel;
	return $rel;
}

# Pour éviter d'avoir des die partout dans le code
sub system_or_die
{
	my ($command)=@_;
	my $rv=system($command);
	if ($rv>>8 != 0)
	{
		die "Commande $command a echoué.\n";
	}

}

sub dest_dir
{
	my ($version)=@_;
	return("${work_dir}/postgresql-${version}");
}

sub build
{
	my ($tobuild)=@_;
	my $dest=dest_dir($tobuild);
	# Options de compil par défaut
	undef $ENV{CC};
	undef $ENV{CFLAGS};
	$configopt="--prefix=$dest --enable-thread-safety --with-openssl --with-libxml --enable-nls --enable-debug";
	my $tag=version_to_REL($tobuild);
	clean($tobuild);
	mkdir ("${dest}") or die "Cannot mkdir ${dest} : $!\n";
	chdir "${dest}" or die "Cannot chdir ${dest} : $!\n";
	system_or_die("git clone ${git_local_repo} src");
	chdir "src" or die "Cannot chdir src : $!\n";
	system_or_die("git reset --hard");
	system_or_die("git checkout $tag"); # à tester pour le head
	system_or_die("rm -rf .git"); # On se moque des infos git maintenant
#	system_or_die ("cp -rf ${git_local_repo}/../xlogdump ${dest}/src/contrib/");
	special_case_compile($tobuild);
	system_or_die("./configure $configopt");
	system_or_die("nice -19 make -j${parallelisme} && make check && make install && cd contrib && make -j3 && make install");
}


# Pour celle la, il faut avoir les tar.gz de toutes les libs en dessous, dans la bonne version. C'est
# basique pour le moment, mais on fait peu de postgis, donc pas eu envie de m'emmerder :)
sub build_postgis
{
	my ($tobuild)=@_;
	# Test que le LD_LIBRARY_PATH est bon avant d'aller plus loin
	unless (defined $ENV{LD_LIBRARY_PATH} and $ENV{LD_LIBRARY_PATH} =~ /proj/)
	{
		die "Il faut que le LD_LIBRARY_PATH soit positionné. Lancez ce script en mode env, et importez les variables\n";
	}

	my $geos='geos-3.3.6';
	my $proj='proj-4.8.0';
	my $jsonc='json-c-0.9';
	my $gdal='gdal-1.9.2';
	my $postgis='postgis-2.0.4';
#	if compare_versions(
	my $dest=dest_dir($tobuild);
	chdir("$work_dir/postgis") or die "Ne peux pas entrer dans $work_dir/postgis:$!\n";
	system("rm -rf $geos $proj $postgis $jsonc $gdal");
	system_or_die("tar xvf ${geos}.tar.bz2");
	chdir($geos);
	system_or_die("./configure --prefix=${dest}/geos");
	system_or_die("make -j $parallelisme && make install");
	chdir ('..');
	system_or_die("tar xvf ${proj}.tar.gz");
	chdir ($proj) or die "Ne peux pas entrer dans $proj:$!\n";
	system_or_die("./configure --prefix=${dest}/proj");
	system_or_die("make -j $parallelisme && make install");
	chdir ('..');
	system_or_die("tar xvf ${jsonc}.tar.gz");
	chdir($jsonc) or die "Ne peux pas entrer dans $jsonc:$!\n";
	system_or_die("./configure --prefix=${dest}/jsonc");
	system_or_die("make && make install");
	chdir('..');
	system_or_die("tar xvf ${gdal}.tar.gz");
	chdir($gdal) or die "Ne peux pas entrer dans $gdal:$!\n";
	system_or_die("./configure --prefix=${dest}/gdal");
	system_or_die("make -j $parallelisme && make install");
	chdir('..');
	system_or_die("tar xvf ${postgis}.tar.gz");
	chdir($postgis) or die "Ne peux pas entrer dans $postgis:$!\n";
	system_or_die("./configure --with-geosconfig=${dest}/geos/bin/geos-config --with-projdir=${dest}/proj --with-jsondir=${dest}/jsonc --with-gdalconfig=${dest}/gdal/bin/gdal-config --prefix=${dest}/postgis");
	system_or_die("make -j $parallelisme");  # Ne marche pas totalement. On gagne quand même du temps
	system_or_die("make && make install");
	print "Compilation postgis OK\n";

}

sub list
{
	my @list=<$work_dir/postgresql-*/>;
	my @retour;
	foreach my $elt (sort @list)
	{
		my $basename_rep_git=basename($git_local_repo); # Il va souvent être dans le même répertoire. Il faut l'ignorer
		next if ($elt =~ /$basename_rep_git/);
		$elt=~/postgresql-(.*)\/$/;
		push @retour,($1);
	}
	return (\@retour);
}
sub list_avail
{
	chdir ("$git_local_repo") or die "Il n'y a pas de répertoire $git_local_repo\nClones en un à coup de git clone git://git.postgresql.org/git/postgresql.git";
	my @versions=`git tag`;
	my @retour;
	foreach my $version(@versions)
	{
		chomp $version;
		next unless ($version =~ /^REL/);
		next if ($version =~ /RC|BETA|ALPHA/);
		$version =~ s/^REL//g;
		$version =~ s/_/./g;
		push @retour, ($version)
	}
	return(\@retour);
}

sub ls_latest
{
	my $refversions=list_avail();
	my $prevversion='';
	my $prevmajeur='';
	my @retour;
	foreach my $version(@$refversions)
	{
		$version=~/^(\d+\.\d+)/;
		my $majeur=$1;
		if ($prevmajeur and ($majeur ne $prevmajeur))
		{
			push @retour, ($prevversion);
		}
		$prevmajeur=$majeur;
		$prevversion=$version;
	}
	push @retour, ($prevversion);
	return(\@retour);
}

sub rebuild_latest
{
	my @latest=@{ls_latest()};
	foreach my $version(@latest)
	{
		my $deja_compile=0;
		my ($majeur1,$majeur2)=majeur_mineur($version);
		my @olddirs=<$work_dir/postgresql-${majeur1}.${majeur2}*>;
		# Le nom des olddirs va ressembler à /home/marc/postgres/postgresql-9.3.0
		foreach my $olddir(@olddirs)
		{
			$olddir=~ /(\d+\.\d+\.\d+)$/ or die "Nom de dir bizarre: $olddir\n";
			my $oldversion=$1;
			if (compare_versions($oldversion,$version)==0)
			{
				print "La version $version est deja compilee.\n";
				$deja_compile=1;
			}
			else
			{
				print "Suppression de la version obsolete $oldversion.\n";
				system_or_die ("rm -rf $olddir");
			}
		}
		# Seulement les versions >= 8.4 (versions supportées)
		unless ($deja_compile or compare_versions($version,'8.4.0')==-1)
		{
			print "Compilation de $version.\n";
			build($version);
		}
	}
}

sub clean
{
	my ($version)=@_;
	my $dest=dest_dir($version);
	stop($version,'immediate'); # Si ça ne réussit pas, tant pis
	system_or_die("rm -rf $dest");
}
#
# Cette fonction ne fait qu'afficher le shell à exécuter
# On ne peut évidemment pas modifier l'environnement du shell appelant directement en perl
# Elle doit être appelée par le shell avec un ` `
sub env
{
	unless ($version)
	{
		print STDERR "Hé, j'ai besoin d'un numero de version\n";
		die;
	}
	# On nettoie le path des anciennes versions, au cas où
	my $oldpath=$ENV{PATH};
	$oldpath =~ s/${work_dir}.*?\/bin://g;
	my $dir=dest_dir($version);
	print "export PATH=${dir}/bin:" . $oldpath . "\n";
	print "export PAGER=less\n";
	print "export PGDATA=${dir}/data\n";
	print "export LD_LIBRARY_PATH=${dir}/proj/lib:${dir}/geos/lib:${dir}/jsonc/lib:${dir}/gdal/lib\n";
	print "export pgversion=$version\n";
	if ($version =~ /^(\d+)\.(\d+)\.(?:(\d+)|(alpha|beta|rc)(\d+))?$/)
	{
		my $minor='';
		if (defined $4)
		{
			my $prefix;
			if ($4 eq 'alpha')
			{
				$prefix='0';
			}
			elsif ($4 eq 'beta')
			{
				$prefix='1';
			}
			else
			{
				$prefix='2';
			}
			# On part de l'hypothèse qu'il n'y a pas plus de 9 betas/alphas/rc
			$minor=$prefix.$5;
		}
		else
		{
			$minor=$3;
		}
		# Version numérique
		print "export PGPORT=5".$1.$2.$minor."\n";
	}
	elsif ($version eq 'review')
	{
		print "export PGPORT=6666\n";
	}
	elsif ($version eq 'dev')
	{
		print "export PGPORT=6667\n";
	}
	else
	{
		die "Version incompréhensible: <$version>\n";
	}
}

sub start
{
	my ($version)=@_;
	my $dir=dest_dir($version);
	$ENV{LANG}="en_GB.utf8";
	unless (-f "$dir/bin/pg_ctl")
	{
		die "Pas de binaire $dir/bin/pg_ctl\n";
	}
	my $pgdata="$dir/data";
	$ENV{PGDATA}=$pgdata;
	if (! -d $pgdata)
	{ # Création du cluster
		system_or_die("$dir/bin/initdb");
		system_or_die("$dir/bin/pg_ctl -w -o '-c wal_sync_method=fdatasync -c shared_buffers=1GB -c work_mem=32MB -c maintenance_work_mem=1GB -c checkpoint_segments=32' start -l $pgdata/log");
		system_or_die("$dir/bin/createdb"); # Pour avoir une base du nom du dba (/me grosse feignasse)
	}
	else
	{
		system_or_die("$dir/bin/pg_ctl -w -o '-c wal_sync_method=fdatasync -c shared_buffers=1GB -c work_mem=32MB -c maintenance_work_mem=1GB -c checkpoint_segments=32' start -l $pgdata/log");
	}
}

sub stop
{
	my ($version,$mode)=@_;
	if (not defined $mode)
	{
		$mode = 'fast';
	}
	my $dir=dest_dir($version);
	my $pgdata="$dir/data";
	return 1 unless (-e "$pgdata/postmaster.pid"); #pg_ctl aime pas qu'on lui demande d'éteindre une instance éteinte
	$ENV{PGDATA}=$pgdata;
	system_or_die("$dir/bin/pg_ctl -w -m $mode stop");
}

sub git_update
{
	system_or_die ("cd ${git_local_repo} && git pull");
}

GetOptions ("version=s" => \$version,
	    "mode=s" => \$mode,)
         or die("Error in command line arguments\n");

if (not defined $version and (not defined $mode or $mode !~ /list|rebuild_latest|git_update/))
{
	if (defined $ENV{pgversion})
	{
		$version=$ENV{pgversion};
	}
	else
	{
		die "Il me faut une version (option -version, ou bien variable d'env pgversion\n";
	}
}


# Bon j'aurais pu jouer avec des pointeurs sur fonction. Mais j'ai la flemme
if (not defined $mode)
{
	die "Il me faut un mode d'execution: option -mode, valeurs: env,....\n";
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
	start($version);
}
elsif ($mode eq 'stop')
{
	stop($version);
}
elsif ($mode eq 'clean')
{
	clean($version);
}
elsif ($mode eq 'list')
{
	print join("\n",@{list()}),"\n";
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
else
{
	die "Mode $mode inconnu\n";
}
