Les versions comprises:
========================================
9.3.5
9.3.beta2
9.2.rc1
9.4alpha1
dev (head)
9.3.dev (le commit le plus récent sur 9.3)
review (head aussi, mais juste pour bidouiller dans un second rep)

exemple de bashrc:
=======================================
::
  
  function pg()
  {
      source <(/home/marc/postgres/postgres.pl -version $1 -mode env)
  }
  
  export PGMANAGE="/home/marc/postgres/postgres.pl"
  alias pgstart="$PGMANAGE -mode start"
  alias pgstartall="$PGMANAGE -mode startall"
  alias pgstop="$PGMANAGE -mode stop"
  alias pgstopall="$PGMANAGE -mode stopall"
  alias pgrestart="pgstop;pgstart"
  alias pgrestartall="pgstopall;pgstartall"
  alias pgbuild="$PGMANAGE -mode build"
  alias pgbuildpostgis="$PGMANAGE -mode build_postgis"
  alias pgclean="$PGMANAGE -mode clean"
  alias pgls="$PGMANAGE -mode list"
  alias pglsavail="$PGMANAGE -mode list_avail"
  alias pglslatest="$PGMANAGE -mode list_latest"
  alias pgrebuild="$PGMANAGE -mode rebuild_latest"
  alias pggitupdate="$PGMANAGE -mode git_update"
  alias pgdoxy="$PGMANAGE -mode doxy"
  alias pgslave="$PGMANAGE --mode slave"
  # Juste là à titre d'exemple
  #export PGSUPARGS='-c fsync=off -c shared_buffers=1GB'
  export PGHOST=/tmp``

