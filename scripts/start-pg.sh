#!/bin/bash

function createIp {
  startIpInput=$1
  index=$2

  #change internal field separator
  oldIFS=$IFS
  IFS=.
  #parse IP into array
  ary=($startIpInput)
  #reset internal field separator
  IFS=$oldIFS

  ip=""
  #create C-Net of Ip
  for (( i=0; i<$((${#ary[@]}-1)); i++ ))
  do
    ip="$ip${ary[$i]}."
  done

  #create D-Net of Ip
  ip="$ip$((${ary[-1]}+$index))"
  printf $ip
}

clusterName=$1
startIpZooKeepers=$2
amountZooKeepers=$3
startIpPostgres=$4
amountPostgres=$5
myIndex=$6
adminUsername=$7
adminPassword=$8

pgversion=9.5
patroniversion=6eb2e2114453545256ac7cbfec55bda285ffb955
patroniDir=/usr/local/patroni-master
patroniCfg=$patroniDir/postgres.yml
hacfgFile=${patroniDir}/postgresha.cfg

cat > /usr/local/startup.log <<-EOF
	Cluster name:        $clusterName
	Zookeepers start IP: $startIpZooKeepers
	Zookeepers:          $amountZooKeepers
	Postgres start IP:   $startIpPostgres
	Postgres:            $amountPostgres
	Admin user:          $adminUsername
	Admin password:      $adminPassword
	MyIndex:             $myIndex
	patroniversion:      $patroniversion
EOF

sudo chmod 666 /usr/local/startup.log

# install saltstack

curl -L https://bootstrap.saltstack.com -o bootstrap_salt.sh
sudo sh bootstrap_salt.sh

# configure saltstack

cat >> /etc/salt/minion <<-EOF
	file_client: local
EOF

mkdir --parents /srv/salt

cat > /srv/salt/top.sls <<-EOF
	base:
	  '*':
	    - webserver
	    - postgres-pkgs
	    - patroni
EOF

cat > /srv/salt/webserver.sls <<-EOF 
	python-pip:
	  pkg.installed
	webserver:
	  pkg.installed:
	    - pkgs:
	      - mdadm
	      - xfsprogs
	      - libpq-dev
	      - python-dev
	      - haproxy
	      - supervisor
	  pip.installed:
	    - require:
	      - pkg: python-pip
	    - upgrade:
	      - pip >= 9.0.1
	      - PyYAML
	      - requests
	      - six
	      - prettytable
	    - names:
	      - boto
	      - psycopg2
	      - kazoo
	      - python-etcd
	      - python-consul
	      - click
	      - tzlocal
	      - python-dateutil
	      - urllib3
	      - PySocks
EOF

cat > /srv/salt/postgres-pkgs.sls <<-EOF 
	postgres-pkgs:
	  pkg.installed:
	    - pkgs:
	      - postgresql-$pgversion
	      - postgresql-contrib-$pgversion

	postgres_repo:
	  pkgrepo.managed:
	    - name: "deb http://apt.postgresql.org/pub/repos/apt/ {{ grains['oscodename'] }}-pgdg main"
	    - file: /etc/apt/sources.list.d/pgdg.list
	    - key_url: https://www.postgresql.org/media/keys/ACCC4CF8.asc
	    - require_in:
	        - pkg: postgres-pkgs
EOF

cat > /srv/salt/patroni.sls <<-EOF 
	patroni:
	  pkg.installed:
	    - pkgs:
	      - unzip
	  cmd.run:
	    - name: curl -L https://github.com/zalando/patroni/archive/${patroniversion}.zip -o /etc/salt/patroni-${patroniversion}.zip
	    - creates: /etc/salt/patroni-${patroniversion}.zip
	  archive.extracted:
	    - name: /tmp/patroni-${patroniversion}
	    - source: /etc/salt/patroni-${patroniversion}.zip
	    - use_cmd_unzip: true
	    - force: true
	  file.copy:
	    - source: /tmp/patroni-${patroniversion}/patroni-${patroniversion}
	    - name: ${patroniDir}
	    - force: true
EOF

salt-call --local state.apply

export PATH=/usr/lib/postgresql/${pgversion}/bin:$PATH

# create RAID

sudo chmod +x ./setup-raid.sh
sudo ./setup-raid.sh /mnt/database
sudo mkdir /mnt/database/data
sudo chmod 777 /mnt/database/data

# write configuration
echo "START IP PROGRESS $startIpPostgres"

sudo cat > $patroniCfg <<-EOF 
	scope: &scope $clusterName
	ttl: &ttl 30
	loop_wait: &loop_wait 10
EOF


if [ $myIndex -eq 0 ] then
sudo cat >> $patroniCfg <<-EOF 
	name: postgres$myIndex
EOF
fi

#  listen: 10.0.101.$(($myIndex + 10)):8008
#  connect_address: 10.0.101.$(($myIndex + 10)):8008

sudo cat  >> $patroniCfg <<-EOF
	restapi:
	  listen: $(createIp $startIpPostgres $myIndex):8008
	  connect_address: $(createIp $startIpPostgres $myIndex):8008
	zookeeper:
	  scope: *scope
	  session_timeout: *ttl
	  reconnect_timeout: *loop_wait
	  hosts:

EOF

i=0
while [ $i -lt $amountZooKeepers ] do
	sudo cat >> $patroniCfg <<-EOF 
	    - $(createIp $startIpZooKeepers $i):2181
	EOF
	i=$(($i+1))
done

echo "" >> $patroniCfg

if [ $myIndex -eq 0 ] then
	sudo cat >> $patroniCfg <<-EOF 
	bootstrap:
	  dcs:
	    ttl: *ttl
	    loop_wait: *loop_wait
	    retry_timeout: *loop_wait
	    maximum_lag_on_failover: 1048576
	    postgresql:
	      use_pg_rewind: true
	      use_slots: true
	      parameters:
	        archive_mode: "on"
	        archive_timeout: 1800s
	        archive_command: mkdir -p ../wal_archive && test ! -f ../wal_archive/%f && cp %p ../wal_archive/%f
	      recovery_conf:
	        restore_command: cp ../wal_archive/%f %p
	  initdb:
	  - encoding: UTF8
	  - data-checksums
	  pg_hba:
	  - host replication all 0.0.0.0/0 md5
	  - host all all 0.0.0.0/0 md5
	  users:
	    admin:
	      password: "$adminPassword"
	      options:
	        - createrole
	        - createdb
EOF
fi

sudo cat >> $patroniCfg <<-EOF 
	tags:
	  nofailover: false
	  noloadbalance: false
	  clonefrom: false

	postgresql:
EOF

if [ $myIndex -ne 0 ] then
	sudo cat >> $patroniCfg <<-EOF 
    	  name: postgres${myIndex}
EOF
fi


sudo cat >> $patroniCfg <<-EOF 
	  listen: '*:5433'
	  connect_address: $(createIp $startIpPostgres $myIndex):5433
	  data_dir: /mnt/database/data/postgresql
	  pgpass: /tmp/pgpass
EOF

if [ $myIndex -ne 0 ] then
sudo cat >> $patroniCfg <<-EOF 
	  maximum_lag_on_failover: 1048576
	  use_slots: true
	  initdb:
	    - encoding: UTF8
	    - data-checksums
	  pg_rewind:
	    username: postgres
	    password: "$adminPassword"
	  pg_hba:
	    - host replication all 0.0.0.0/0 md5
	    - host all all 0.0.0.0/0 md5
	  replication:
	    username: replicator
	    password: "$adminPassword"
	  superuser:
	    username: postgres
	    password: "$adminPassword"
	  admin:
	    username: admin
	    password: "$adminPassword"
	  create_replica_method:
	    - basebackup
	  recovery_conf:
	    restore_command: cp ../wal_archive/%f %p
	  parameters:
	    archive_mode: "on"
	    wal_level: hot_standby
	    archive_command: mkdir -r ../wal_archive && test ! -f ../wal_archive/%f && cp %cp ../wal_archive/%f
	    max_wal_senders: 10
	    wal_keep_segments: 8
	    archive_timeout: 1800s
	    max_replication_slots: 10
	    hot_standby: "on"
	    wal_log_hints: "on"
	    unix_socket_directories: '.'
	EOF
  else
	sudo cat >> $patroniCfg <<-EOF 
		  authentication:
		    replication:
		      username: replicator
		      password: "$adminPassword"
		    superuser:
		      username: postgres
		      password: "$adminPassword"
		  parameters:
		    unix_socket_directories: '.'
	EOF
fi

sudo chmod 666 $patroniCfg

sudo cat > $hacfgFile <<-EOF 
	global
	    maxconn 100

	defaults
	    log     global
	    mode    tcp
	    retries 2
	    timeout client 30m
	    timeout connect 4s
	    timeout server 30m
	    timeout check 5s

	frontend ft_postgresql
	    bind *:5000
	    default_backend bk_db

	backend bk_db
	    option httpchk

EOF

i=0
while [ $i -lt $amountPostgres ] do
	sudo cat >> $hacfgFile <<-EOF 
		  server Postgres$i $(createIp $startIpPostgres $i):5433 maxconn 100 check port 8008
	EOF
	i=$(($i+1))
done
sudo chmod 666 $hacfgFile

sudo cat > ${patroniDir}/patroni_start.sh <<-EOF 
	#!/bin/bash
	export PATH=/usr/lib/postgresql/9.5/bin:\$PATH
	${patroniDir}/patroni.py ${patroniCfg}
EOF

sudo chmod +x ${patroniDir}/patroni_start.sh

sudo cat > /etc/supervisor/conf.d/patroni.conf <<-EOF 
	[program:patroni]
	command=${patroniDir}/patroni_start.sh
	user=$adminUsername
	autostart=true
	autorestart=true
	stderr_logfile=/var/log/patroni.err.log
	stdout_logfile=/var/log/patroni.out.log
EOF

sudo cat > /etc/supervisor/conf.d/haproxy.conf <<-EOF 
	[program:haproxy]
	command=haproxy -D -f $hacfgFile
	autostart=true
	autorestart=true
	stderr_logfile=/var/log/haproxy.err.log
	stdout_logfile=/var/log/haproxy.out.log
EOF

sudo service supervisor restart
sudo supervisorctl reread
sudo supervisorctl update
