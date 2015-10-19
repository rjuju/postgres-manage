#!/usr/bin/perl -w
use Getopt::Long;
use File::Basename;
use Data::Dumper;
use Digest::MD5 qw(md5);
use File::Copy;


use strict;

# Ces 3 sont en our pour pouvoir les manipuler par référence symbolique (paresse quand tu nous tiens)
# Ça évite de stocker dans un hash, ou de devoir faire une floppée de if dans la fonction
# de chargement de la conf
our $parallelisme;
our $work_dir;
our $git_local_repo;
our $doxy_file;
our $CC;
our $CFLAGS;
our $min_version='9.0';
our $CONFIGOPTS; # Ne pas confondre avec $configopt (la ligne de commande qui va être réellement passée à configure)
our $LD_LIBRARY_PATH; # Ne pas confondre avec $configopt (la ligne de commande qui va être réellement passée à configure)

my $conf_file;

my $version;
my $clusterid;
my $mode;
my $configopt='';

# C'est pas à nous de nous emmerder avec les warnings
$ENV{CFLAGS}="-Wno-error";
$ENV{CXXFLAGS}="-Wno-error";

# Hash utilisé pour décider quelles versions utiliser par rapport à une version de PG
my %postgis_version=(
    '9.2' => {  'geos'   => 'geos-3.3.9',
            'proj'   =>'proj-4.8.0',
            'jsonc'  =>'json-c-0.9',
            'gdal'   =>'gdal-1.9.2',
           'postgis'=>'postgis-2.0.4',
        },
     '9.1' => {  'geos'   => 'geos-3.3.9',
            'proj'   =>'proj-4.8.0',
            'jsonc'  =>'json-c-0.9',
            'gdal'   =>'gdal-1.9.2',
           'postgis'=>'postgis-2.0.4',
        },
    '9.4' => { 'geos'   => 'geos-3.4.2',
            'proj'   =>'proj-4.9.1',
            'jsonc'  =>'json-c-0.12-20140410',
            'gdal'   =>'gdal-2.0.0',
           'postgis'=>'postgis-2.1.7',
        },
    '9.3' => { 'geos'   => 'geos-3.4.2',
                    'proj'   =>'proj-4.9.1',
                    'jsonc'  =>'json-c-0.12',
                    'gdal'   =>'gdal-1.11.2',
                   'postgis'=>'postgis-2.1.0',
                },
            '9.4' => { 'geos'   => 'geos-3.4.2',
            'proj'   =>'proj-4.8.0',
            'jsonc'  =>'json-c-0.9',
            'gdal'   =>'gdal-1.9.2',
           'postgis'=>'postgis-2.1.0',
        },
    '8.2' => { 'geos'   => 'geos-3.3.9',
            'proj'   =>'proj-4.5.0',
            'gdal'   =>'gdal-1.9.2',
           'postgis'=>'postgis-1.3.2',
        },
);

# Hash utilisé pour donner la correspondance entre une regexp de nom de fichier à télécharger et son URL
# Les fonctions anonymes sont volontairement compactes :)
# Si ça devient trop chiant, à la place, faudra retourner une liste d'URL candidates, et toutes les tester.
# Les règles de rangement sur ces projets, c'est n'importe quoi
my %tar_to_url=(
    'json-c-\d+\.\d+-\d+\.tar\.gz' => sub { return ("https://github.com/json-c/json-c/archive/" . $_[0])},
    'json-c-\d+\.\d+\.tar\.gz' => sub { return ("https://github.com/downloads/json-c/json-c/" . $_[0])},
    'gdal' => sub { $_[0] =~ /gdal-(.+?)\.tar\.gz/;
                    my $version=$1;
                    if (compare_versions($version,'1.10.2')>=0) # Le fichier est dans un sous-répertoire
                    {
                       return ("http://download.osgeo.org/gdal/" . $version . '/' . $_[0] )
                    }
                    return ("http://download.osgeo.org/gdal/${_[0]}")
                  },
    'proj' => sub { return ("http://download.osgeo.org/proj/" . $_[0])},
    'geos' => sub { return ("http://download.osgeo.org/geos/" . $_[0])},
    'postgis' => sub { return ("http://download.osgeo.org/postgis/source/" . $_[0])},
);


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
    elsif ($mineur =~ /^dev$/)
    {
            $score=400;
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
    # Cas de sortie:
    return 1 if ($version1 eq 'dev' or $version1 eq 'review');
    return -1 if ($version2 eq 'dev' or $version2 eq 'review');
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
    # dev>rc>beta>alpha. Pour rendre la comparaison simple, alpha=0, beta=100, rc=200, final=300, dev (head de la branche)=400.
    # On les somme au numéro de version trouvé. C'est ce que fait la fonction calcule_mineur
    my $score1=calcule_mineur($mineur1);
    my $score2=calcule_mineur($mineur2);
    return $score1<=>$score2;
}

# Cette fonction rajoute des options de config pour les cas spéciaux (vieilles versions avec pbs d'options de compil, etc
# Cette fonction utilise la fonction de comparaisons de versions pour faire ses petites affaires.
# On y change les configopt au besoin, l'environnement (CC, CFLAGS…)
# Pour éviter les optimisations qui empêchent l'initdb
sub special_case_compile
{
    my ($version)=@_;
    if (compare_versions($version,'9.0.0') < 0)
    {
        $ENV{CFLAGS}.=' -O0';
    }
    return $configopt;
}

# Convertir une version en tag git
sub version_to_REL
{
    my ($version)=@_;
    my $rel=$version;
    if  ($version =~ /^dev$|^review$/)
    {
        return 'master';
    }
    elsif ($version =~ /(\d+\.\d+)\.dev$/)
    {
        # Cas particulier: pas de tag, faut aller chercher origin/REL9_0_STABLE par exemple
        $rel=~ s/\./_/g;
        $rel=~ s/^/origin\/REL/;
        $rel=~ s/_dev$/_STABLE/;
        return $rel;
    }
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
    my ($command,$mute)=@_;
    $mute=0 unless defined($mute);
    my $fh;
    my @retour;
    open($fh,'-|',$command) or die "Impossible de lancer $command: $!";
    while (my $line=<$fh>)
    {
        push @retour,($line);
        unless ($mute)
        {
            print $line;
        }
    }
    close ($fh);
    if ($?>>8 != 0)
    {
        die "Commande $command a echoué.\n";
    }
    return \@retour; # Par référence, ça peut être gros sinon :)
}

sub dest_dir
{
    my ($version)=@_;
    return("${work_dir}/postgresql-${version}");
}

sub get_pgdata
{
    my ($dir, $clusterid) = @_;
    my $id = '';
    $id = $clusterid if $clusterid ne 0;
    return "$dir/data$id";
}

sub get_pgport
{
    my ($version, $clusterid) = @_;
    return unpack('n',pack('B15','0'.substr(unpack('B128',md5($version.$clusterid)),0,15))) + 1025;
}

sub build
{
    my ($tobuild)=@_;
    my $dest=dest_dir($tobuild);
    # Options de compil par défaut
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
    # construction du configure
    $configopt="--prefix=$dest $CONFIGOPTS";
    my $tag=version_to_REL($tobuild);
    # on garde les données
    clean($tobuild, 0);
    mkdir ("${dest}");
    # le mkdir du répertoire est facultatif, il a pu être conservé par le clean
    # si ce n'est pas le premier build de cette version
    die "Cannot mkdir ${dest} : $!\n" if (not -d ${dest});
    chdir "${dest}" or die "Cannot chdir ${dest} : $!\n";
    mkdir ("src") or die "Cannot mkdir src : $!\n";
    mkdir ("src/.git") or die "Cannot mkdir src/.git : $!\n";
    system_or_die("git clone --mirror ${git_local_repo} src/.git");
    chdir "src" or die "Cannot chdir src : $!\n";
    system_or_die("git config --bool core.bare false");
    system_or_die("git reset --hard");
    system_or_die("git checkout $tag"); # à tester pour le head
    system_or_die("rm -rf .git"); # On se moque des infos git maintenant
#   system_or_die ("cp -rf ${git_local_repo}/../xlogdump ${dest}/src/contrib/");
    special_case_compile($tobuild);
    print "./configure $configopt\n";
    system_or_die("./configure $configopt");
    system_or_die("nice -19 make -j${parallelisme} && make check && make install && cd contrib && make -j3 && make install");
}

# Fonction générique de compilation.
sub build_something
{
    my ($tar,@commands)=@_;
    # Some files may not have been downloaded. Try to get them
    try_download($tar) if ((! -f $tar) or (-z $tar));
    print "Décompression de $tar\n";
    my $retour_tar=system_or_die("tar xvf $tar",1); # 1 = mute, on veut aps voir le tar à l'écran
    # On va prendre la première ligne pour savoir dans quel répertoire ça a décompressé (y a le projet json-c où ils sont niais :) )
    $retour_tar->[0] =~ /^(.*)\// or die "Impossible de trouver le répertoire de " . $retour_tar->[0];
    my $dir = $1;
    chdir ($dir);
    foreach my $command(@commands)
    {
        system_or_die($command);
    }
    chdir ('..');
    system_or_die("rm -rf $dir");
}

# Find the file
# We'll use regexps to guess what we are trying to download :)
sub try_download
{
    my ($file)=@_;
    # Recherche de l'entrée de %tar_to_url qui corresponde (regexp)
    my $url;
    my $found=0;
    while (my ($regexp,$subref)=each %tar_to_url)
    {
       next unless $file =~ /$regexp/;
       $found=1;
       $url=&{$subref}($file);
    }
    die "Impossible de trouver l'URL de $file" unless ($found);
    unlink ("$work_dir/postgis/$file"); # On essaye de supprimer l'ancien avant. Normalement, y a pas
    print "Téléchargement de $file : wget $url -O $work_dir/postgis/$file\n";
    system("wget $url -O $work_dir/postgis/$file");
    unless ($? >>8 == 0)
    {
        move ("$work_dir/postgis/$file","$work_dir/postgis/$file.failed");
        die "Cannot download $file";
    }
}

# Génération d'un doxygen. À partir d'un fichier Doxyfile qui doit être indiqué dans la conf.
sub doxy
{
    my ($version)=@_;
    my $dest=dest_dir($version);
    # Creation du fichier doxygen
    my $src_doxy="${dest}/src/";
    my $dest_doxy="${dest}/doxygen/";
    mkdir("${dest_doxy}");
    open DOXY_IN,$doxy_file or die "Impossible de trouver le fichier de conf doxygen $doxy_file: $!";
    open DOXY_OUT,"> ${dest_doxy}/Doxyfile" or die "Impossible de créer ${dest_doxy}/Doxyfile: $!";
    while (my $line=<DOXY_IN>)
    {
        $line =~ s/\$\$OUT_DIRECTORY\$\$/${dest_doxy}/;
        $line =~ s/\$\$IN_DIRECTORY\$\$/${src_doxy}/;
        $line =~ s/\$\$VERSION\$\$/$version/;
        print DOXY_OUT $line;
    }
    close DOXY_OUT;
    close DOXY_IN;
    # On peut générer le doxygen
    system("doxygen ${dest_doxy}/Doxyfile");
    # Maintenant, vu la quantité de fichiers html dans le résultat, on crée une page index.html
    # à la racine du rep doxy, qui redirige
    open DOXY_OUT,"> ${dest_doxy}/index.html" or die "impossible de créer ${dest_doxy}/index.html: $!";
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

# Pour celle la, il faut avoir les tar.gz de toutes les libs en dessous, dans la bonne version. C'est
# basique pour le moment, mais on fait peu de postgis, donc pas eu envie de m'emmerder :)
sub build_postgis
{
    my ($tobuild)=@_;
    # Test que le LD_LIBRARY_PATH est bon avant d'aller plus loin
    # Si la personne l'a positionné elle même, c'est pour ses pieds :)
    unless ((defined $ENV{LD_LIBRARY_PATH} and $ENV{LD_LIBRARY_PATH} =~ /proj/) or defined $LD_LIBRARY_PATH)
    {
        die "Il faut que le LD_LIBRARY_PATH soit positionné. Lancez ce script en mode env, et importez les variables\n";
    }
    my ($majeur1,$majeur2)=majeur_mineur($tobuild);
    my $majeur=$majeur1 . '.' . $majeur2;
    unless (defined $postgis_version{$majeur})
    {
        die "Impossible de déterminer les versions de postgis à utiliser pour la version postgres $majeur";
    }
    no warnings; # Il va y avoir de l'undef ci-dessous
    my $refversion=$postgis_version{$majeur};
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
    chdir($postgisdir) or die "Ne peux pas entrer dans $postgisdir\n";
    system("rm -rf $geos $proj $postgis $jsonc $gdal");

    use warnings;

    my $dest=dest_dir($tobuild);

    my $postgis_options='';
    # On va modifier le PATH au fur et à mesure de la compil: les vieilles versions de postgis ne prenaient pas les chemins dans le configure
    if (defined $geos)
    {
        build_something("${geos}.tar.bz2","./configure --prefix=${dest}/geos","make -j $parallelisme","make install");
        $postgis_options.=" --with-geosconfig=${dest}/geos/bin/geos-config";
        $ENV{PATH}="${dest}/geos/bin/" . ':' . $ENV{PATH};
    }
    if (defined $proj)
    {
        build_something("${proj}.tar.gz","./configure --prefix=${dest}/proj","make -j $parallelisme","make install");
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
        build_something("${gdal}.tar.gz","./configure --prefix=${dest}/gdal","make -j $parallelisme","make install");
        $postgis_options.=" --with-gdalconfig=${dest}/gdal/bin/gdal-config";
    }
    build_something("${postgis}.tar.gz","./configure $postgis_options --prefix=${dest}/postgis","make -j $parallelisme","make","make install");
    print "Compilation postgis OK\n";

}

sub list
{
    print "  Instance     Port Esclave?\n";
    print "-----------------------------\n";
    my @list=<$work_dir/postgresql-*/>;
    foreach my $ver (sort @list)
    {
        my $basename_rep_git=basename($git_local_repo); # Il va souvent être dans le même répertoire. Il faut l'ignorer
        next if ($ver =~ /$basename_rep_git/);
        $ver =~ /postgresql-(.*)\/$/;
        my $cur = $1;
        my @list2 = <$work_dir/postgresql-$cur/data*>;
        my $nb = 0;
        foreach my $inst (sort @list2)
        {
            $inst =~ /data(\d*)$/;
            my $id = $1;
            $id = 0 if ($id eq '');
            my $port = get_pgport($cur, $id);
            if (-f "$inst/postmaster.pid")
            {
                printf "*"
            }
            else {
                printf " "
            }
            printf " ";
            printf "%-12s", "$cur/$id";
            printf "%5s ", get_pgport($cur, $id);
            if (-f "$inst/recovery.conf")
            {
                print "Oui";
            }
            else
            {
                print "Non";
            }
            print "\n";
            $nb++;
        }
        if ($nb == 0)
        {
            printf "  %-16s", "$cur";
            printf "%-5s", "-";
            print "\n";
        }
    }
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
    foreach my $version(sort {compare_versions($a,$b) } @$refversions)
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
            next if ($olddir =~ /dev$/ or $olddir =~ /review$/);
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
                # on conserve les répertoire $PGDATA cependant
                clean($olddir, 0);
            }
        }
        # Seulement les versions >= $min_version (versions supportées)
        unless ($deja_compile or compare_versions($version,$min_version)==-1)
        {
            print "Compilation de $version.\n";
            build($version);
        }
    }
}

sub clean
{
    my ($version, $remove_data)=@_;
    $remove_data = 0 if not defined $remove_data;
    my $dest=dest_dir($version);
    stop_all_clusters($version,'immediate'); # Si ça ne réussit pas, tant pis
    if ($remove_data)
    {
        # on supprime tout le répertoire, y compris les données
        system_or_die("rm -rf $dest");
    } else {
        # si le répertoire n'existe pas (premier build), rien à faire
        return if (not -d $dest);
        # on conserve les données
        system_or_die("find $dest -mindepth 1 -maxdepth 1 -type d -path '*data*' -prune -o -exec rm -rf {} \\;");
    }
}

sub cluster_exists
{
    my ($version, $clusterid) = @_;
    my $dir = dest_dir($version);
    my $pgdata = get_pgdata($dir, $clusterid);

    return 0 if (not -d $pgdata);
    return 1;
}
#
# Cette fonction créé un nouvel esclave à partir d'un cluster existant.
# Un recovery.conf sera automatiquement généré avec une connexion en SR.
# Les version 8.4- ne sont pas supportées.
sub add_slave
{
    my ($version, $clusterid) = @_;

    if (compare_versions($version, '9.0') == -1)
    {
    die "Seuls les esclaves en S/R sont supportés.";
    }
    die "L'instance $version/$clusterid n'existe pas !" if not cluster_exists($version, $clusterid);

    my $newclusterid = $clusterid;
    my $ok = 0;
    while (not $ok)
    {
        $newclusterid++;
        $ok = 1 if (not cluster_exists($version, $newclusterid));
    }
    print "L'esclave sera $version/$newclusterid\n";

    # Arrêt du serveur source
    stop_one_cluster($version,$clusterid);

    print "Copie des données...\n";
    my $dir = dest_dir($version);
    my $pgdata_src = get_pgdata($dir,$clusterid);
    my $pgdata_dst = get_pgdata($dir,$newclusterid);
    my $pgport = get_pgport($version, $clusterid);
    system_or_die("cp -R $pgdata_src $pgdata_dst");
    system_or_die("find $pgdata_dst/pg_xlog/ -type f -delete");

    print "Génération du recovery.conf\n";
    my $recovery = "$pgdata_dst/recovery.conf";
    open RECOVERY_CONF, "> $recovery" or die "Impossible de créer $recovery: $!";
    print RECOVERY_CONF "standby_mode = 'on'\n";
    print RECOVERY_CONF "primary_conninfo = 'host=127.0.0.1 port=$pgport application_name=\"$version/$newclusterid\"'\n";
    close RECOVERY_CONF;

    print "Esclave $version/$newclusterid prêt !"
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
    if (not defined $clusterid)
    {
        print STDERR "Hé, j'ai besoin d'un numero de cluster\n";
        die;
    }
    # on retourne une erreur ici si le numéro de version n'est pas reconnu
    unless ($version =~ /^((\d+)\.(\d+)\.(?:(\d+)|(alpha|beta|rc)(\d+)|(dev))?)|(dev|review)$/)
    {
        print STDERR "Version incompréhensible: <$version>\n";
        die;
    }
    # On nettoie le path des anciennes versions, au cas où
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

    # Pour LD_LIBRARY_PATH: on garde ce qu'on a, et on ajoute soit la valeur par défaut, soit ce que l'utilisateur a en place dans la conf
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
    # Génération d'un numéro de port à partir d'un hash de la version et du n° de cluster
    my $pgport=get_pgport($version, $clusterid);
    print "export PGPORT=$pgport\n";
}

sub start_one_cluster
{
    my ($version,$clusterid)=@_;
    my $dir=dest_dir($version);
    $ENV{LANG}="en_GB.utf8";
    print "Démarrage du cluster $version/$clusterid...\n";
    unless (-f "$dir/bin/pg_ctl")
    {
        die "Pas de binaire $dir/bin/pg_ctl\n";
    }
    my $pgdata=get_pgdata($dir,$clusterid);
    $ENV{PGDATA}=$pgdata;
    my $args;
    if (compare_versions($version,'8.2')==-1) # Plus vieille qu'une 8.2
    {
        $args="-c wal_sync_method=fdatasync -c sort_mem=32000 -c vacuum_mem=32000 -c checkpoint_segments=32";
    }
    elsif (compare_versions($version, "9.5") >= 0)
    {
        $args="-c wal_sync_method=fdatasync -c work_mem=32MB -c maintenance_work_mem=1GB -c min_wal_size=512MB -c max_wal_size=1500MB";
    }
    else
    {
        $args="-c wal_sync_method=fdatasync -c work_mem=32MB -c maintenance_work_mem=1GB -c checkpoint_segments=32";
    }
    if (defined ($ENV{PGSUPARGS}))
    {
        $args=$args . " " . $ENV{PGSUPARGS};
    }
    if (! -d $pgdata)
    { # Création du cluster
        system_or_die("$dir/bin/initdb");
        system_or_die("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
        system_or_die("$dir/bin/createdb"); # Pour avoir une base du nom du dba (/me grosse feignasse)
    }
    else
    {
        system_or_die("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
    }
}

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

sub stop_one_cluster
{
    my ($version,$clusterid,$mode)=@_;
    if (not defined $mode)
    {
        $mode = 'fast';
    }
    my $dir=dest_dir($version);
    my $pgdata=get_pgdata($dir, $clusterid);
    print "Arrêt de l'instance $version/$clusterid...\n";
    return 1 unless (-e "$pgdata/postmaster.pid"); #pg_ctl aime pas qu'on lui demande d'éteindre une instance éteinte
    $ENV{PGDATA}=$pgdata;
    system("$dir/bin/pg_ctl -w -m $mode stop");
}

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
    system_or_die ("cd ${git_local_repo} && git pull");
}

# La conf est dans un fichier à la .ini. Normalement /usr/local/etc/postgres_manage.conf,
# ou ~/.postgres_manage.conf ou pointée par la variable d'env
# postgres_manage, et sinon, passée en ligne de commande. Les priorités sont évidemment ligne de commande avant environnement
# avant rep par défaut

sub charge_conf
{
    # On détecte l'endroit d'où lire la conf:
    unless (defined $conf_file)
    {
        # Pas de fichier en ligne de commande. On regarde l'environnement
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
        die "Pas de fichier de configuration trouvé, ni passé en ligne de commande (-conf), ni dans \$postgres_manage,\nni dans " . $ENV{HOME} . "/.postgres_manage.conf, ni dans /usr/local/etc/.postgres_manage.conf\n";
    }

    # On cherche 4 valeurs: parallelisme, work_dir, doxy_file et git_local_repo.
    open CONF,$conf_file or die "Pas pu ouvrir $conf_file:$!\n";
    while (my $line=<CONF>)
    {
        no strict 'refs'; # Pour pouvoir utiliser les références symboliques
        my $line_orig=$line;
        $line=~ s/#.*//; # Suppression des commentaires
        $line =~ s/\s*$//; # suppression des blancs en fin de ligne
        next if ($line =~ /^$/); # On saute les lignes vides après commentaires
        $line =~ s/\s*=\s*/=/; # Suppression des blancs autour du =
        # On peut maintenant traiter le reste avec une expression régulière simple :)
        $line =~ /(\S+)=(.*)/ or die "Ligne de conf bizarre: <$line_orig>\n";
        my $param_name=$1; my $param_value=$2;
        ${$param_name}=$param_value; # référence symbolique, par paresse.
    }
    die "Il me manque des paramètres dans la conf" unless (defined $parallelisme and defined $work_dir and defined $git_local_repo and defined $doxy_file);
    unless (defined $CONFIGOPTS)
    {
        $CONFIGOPTS='--enable-thread-safety --with-openssl --with-libxml --enable-nls --enable-debug --with-ossp-uuid';#Valeur par défaut
    }
    close CONF;
}


GetOptions (
    "version=s"     => \$version,
    "mode=s"        => \$mode,
    "conf_file=s"   => \$conf_file
)
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
    if (defined $ENV{pgclusterid})
    {
        $clusterid=$ENV{pgclusterid};
    }
}

# par défaut, on est sur le cluster 0
$clusterid = '0' if not defined($clusterid);
# Si le numéro de version contient un numéro de cluster, on le gère
if (defined $version and $version =~ /^(.+)\/(\d+)$/)
{
    $version = $1;
    $clusterid = int($2);
}

charge_conf();

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
    # on supprime aussi les données
    clean($version, 1);
}
elsif ($mode eq 'slave')
{
    add_slave($version, $clusterid);
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
    die "Mode $mode inconnu\n";
}
