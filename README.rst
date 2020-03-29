Understood versions:
====================

9.3.5
9.3.beta2
9.2.rc1
9.4alpha1
dev (head)
9.3.dev (most recent commit for 9.3 major version)
review (like head, if needed for hacking)

bashrc example:
===============
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
  # Additional usage example
  #export PGSUPARGS='-c fsync=off -c shared_buffers=1GB'
  export PGHOST=/tmp

