BUILD_DIR = $(shell pwd)/build
CN_CONF = $(BUILD_DIR)/run/galaxysql/conf/server.properties
DN_CONF =  $(BUILD_DIR)/run/galaxyengine/my.cnf
CDC_CONF = $(BUILD_DIR)/run/galaxycdc/polardbx-binlog.standalone/conf/config.properties

UNAME_S = $(shell uname -s)
OS = $(shell lsb_release -si)
V = $(shell lsb_release -r | awk '{print $$2}'|awk -F"." '{print $$1}')


.PHONY: polardb-x
polardb-x: gms dn cn cdc configs
	cd $(BUILD_DIR)/run ;				\
	if [ -d "bin" ]; then				\
		rm -rf bin;				\
	fi;						\
	mkdir bin;					\
	echo "$$START_SCRIPT" > bin/polardb-x.sh;	\
	chmod +x bin/polardb-x.sh
	chmod +x $(BUILD_DIR)/run/galaxysql/bin/startup.sh
	chmod +x $(BUILD_DIR)/run/galaxycdc/polardbx-binlog.standalone/bin/daemon.sh

.PHONY: gms
gms: sources deps 
	cd $(BUILD_DIR)/galaxyengine;							\
	cmake	.									\
		-DFORCE_INSOURCE_BUILD=ON						\
		-DCMAKE_BUILD_TYPE="Debug"						\
		-DWITH_XENGINE_STORAGE_ENGINE=OFF					\
		-DMYSQL_MAINTAINER_MODE=0							\
		-DWITH_SSL=openssl									\
		-DSYSCONFDIR="$(BUILD_DIR)/run/galaxyengine/u01/mysql"			\
		-DCMAKE_INSTALL_PREFIX="$(BUILD_DIR)/run/galaxyengine/u01/mysql"	\
		-DMYSQL_DATADIR="$(BUILD_DIR)/run/galaxyengine/u01/mysql/data"		\
		-DWITH_BOOST="./extra/boost/boost_1_70_0.tar.gz" ;			\
	make -j8 && make install

.PHONY: dn
dn: gms

.PHONY: cdc
cdc: sources deps cn
	cd $(BUILD_DIR)/galaxycdc;								\
	mvn install -D maven.test.skip=true -D env=release;					\
	mkdir $(BUILD_DIR)/run/galaxycdc;							\
	cp polardbx-cdc-assemble/target/polardbx-binlog.tar.gz $(BUILD_DIR)/run/galaxycdc/;	\
	cd $(BUILD_DIR)/run/galaxycdc/;								\
	tar xzvf polardbx-binlog.tar.gz

.PHONY: cn
cn: sources deps
	cd $(BUILD_DIR)/galaxysql;					\
	mvn install -D maven.test.skip=true -D env=release;		\
	mkdir $(BUILD_DIR)/run/galaxysql;				\
	cp target/polardbx-server-*.tar.gz $(BUILD_DIR)/run/galaxysql/;	\
	cd $(BUILD_DIR)/run/galaxysql;					\
	tar xzvf polardbx-server-*.tar.gz


DN_DATA_DIR = $(BUILD_DIR)/run/galaxyengine/data

.PHONY: configs
configs: gms dn cdc cn
	# config gms & dn
	echo "$$MY_CNF" > $(DN_CONF)
	mkdir -p $(DN_DATA_DIR)/u01/my3306/data
	mkdir -p $(DN_DATA_DIR)/u01/my3306/log
	mkdir -p $(DN_DATA_DIR)/u01/my3306/run
	mkdir -p $(DN_DATA_DIR)/u01/my3306/tmp
	mkdir -p $(DN_DATA_DIR)/u01/my3306/mysql
	# start gms
	if [ -e "$(DN_DATA_DIR)/u01/my3306/data/auto.cnf" ]; then										\
		echo "gms root account already initialized.";											\
	else																	\
		$(BUILD_DIR)/run/galaxyengine/u01/mysql/bin/mysqld --defaults-file=$(DN_CONF) --initialize-insecure;				\
	fi ;																	\
	$(BUILD_DIR)/run/galaxyengine/u01/mysql/bin/mysqld --defaults-file=$(DN_CONF) -D ;							\
	awk -F"=" '/^serverPort/{$$2="=8527";print;next}1' $(CN_CONF) > tmp && mv tmp $(CN_CONF);						\
	awk -F"=" '/^metaDbAddr/{$$2="=127.0.0.1:4886";print;next}1' $(CN_CONF) > tmp && mv tmp $(CN_CONF);					\
	awk -F"=" '/^metaDbXprotoPort/{$$2="=32886";print;next}1' $(CN_CONF) > tmp && mv tmp $(CN_CONF);					\
	cd $(BUILD_DIR)/run/galaxysql/;														\
	META=`bin/startup.sh -I -P asdf1234ghjk5678 -d 127.0.0.1:4886:32886 -u polardbx_root -S "123456" 2>&1`;				\
	echo "meta: $${META}";															\
	echo "$${META}" | grep "metaDbPass" >> meta.tmp;											\
	META_DB_PASS=`cat meta.tmp | grep "metaDbPass"`;											\
	echo "metadb password: $${META_DB_PASS}";												\
	ps aux|grep "$(BUILD_DIR)/run/galaxyengine/u01/mysql/bin/mysqld" | grep -v "grep" | awk '{print $$2}' |xargs kill;			\
	if [ "" = "$${META_DB_PASS}" ]; then													\
		echo "meta db init failed.";													\
		exit 1;																\
	fi;																	\
	cat meta.tmp >> $(CN_CONF)
	# config cdc	
	cd $(BUILD_DIR)/run/galaxysql/;														\
	META_DB_PASS=`cat meta.tmp | awk -F"=" '{print $$2}'`;											\
	awk -F"=" '/^useEncryptedPassword/{$$2="=true";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);					\
	awk -F"=" '/^polardbx.instance.id/{$$2="=polardbx-polardbx";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);			\
	awk -F"=" '/^metaDb_url/{$$2="=jdbc:mysql://127.0.0.1:4886/polardbx_meta_db_polardbx?useSSL=false";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);			\
	awk -F"=" '/^metaDb_username/{$$2="=my_polarx";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);					\
	sed 's/metaDb_password.*//g' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);									\
	cat meta.tmp >> $(CDC_CONF);														\
	sed 's/metaDbPasswd/metaDb_password/g' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);								\
	awk -F"=" '/^polarx_url/{$$2="=jdbc:mysql://127.0.0.1:8527/__cdc__";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);		\
	awk -F"=" '/^polarx_username/{$$2="=polardbx_root";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);				\
	awk -F"=" '/^polarx_password/{$$2="=UY1tQsgNvP8GJGGP8vHKKA==";print;next}1' $(CDC_CONF) > tmp && mv tmp $(CDC_CONF);			\
	rm meta.tmp

.PHONY: sources
sources: deps
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR);						\
	if [ -d "galaxysql" ]; then 					\
		echo "galaxysql exsits.";				\
	else								\
		git clone https://github.com/apsaradb/galaxysql.git;	\
		cd galaxysql;						\
		git submodule update --init;				\
	fi
	cd $(BUILD_DIR);						\
	if [ -d "galaxyengine" ]; then					\
		echo "galaxyengine exists.";				\
	else								\
		git clone https://github.com/apsaradb/galaxyengine.git;	\
		cd galaxyengine;					\
		wget https://boostorg.jfrog.io/artifactory/main/release/1.70.0/source/boost_1_70_0.tar.gz;	\
		mkdir -p extra/boost;					\
		cp boost_1_70_0.tar.gz extra/boost/;			\
		if [ "$(UNAME_S)" = "Darwin" ]; then			\
			echo "$${VERSION_PATCH}" >> macos.patch;	\
			git apply macos.patch;				\
			rm macos.patch;					\
		fi ;							\
	fi
	cd $(BUILD_DIR);						\
	if [ -d "galaxycdc" ]; then					\
		echo "galaxycdc exists.";				\
	else								\
		git clone https://github.com/apsaradb/galaxycdc.git;	\
	fi

.PHONY: deps
deps:
ifeq ($(UNAME_S), Darwin)
	@echo "Install the following tools and libraries before your building.\n"
	@echo "tools		: cmake3, make, automake, gcc, g++, bison, git, jdk1.8+, maven3"
	@echo "libraries	: openssl1.1 \n\n"
	@echo "Press any key to continue..."
	@read -n 1
else
ifeq ($(OS), CentOS)
	sudo yum install -y git
	sudo yum install -y maven
	sudo yum install -y java-1.8.0-openjdk-devel
	sudo yum remove -y cmake
	sudo yum install -y cmake3
	sudo yum install -y automake
	sudo yum install -y bison
	sudo yum install -y openssl-devel
	sudo yum install -y ncurses-devel
	sudo yum install -y libaio-devel
ifeq ($(V), 8)
	sudo yum install -y libtirpc-devel
	sudo yum install -y dnf-plugins-core
	sudo yum config-manager --set-enabled PowerTools
	sudo yum install -y rpcgen
	sudo yum groupinstall -y "Development Tools"
	sudo yum install -y gcc gcc-c++
endif
ifeq ($(V), 7)
	if [ -e "/usr/bin/cmake" ]; then        \
		sudo rm /usr/bin/cmake -f ;     \
	fi
	sudo ln -s /usr/bin/cmake3 /usr/bin/cmake
	sudo yum install centos-release-scl
	sudo yum install devtoolset-7-gcc devtoolset-7-gcc-c++ devtoolset-7-binutils
	echo "source /opt/rh/devtoolset-7/enable" |sudo tee -a /etc/profile
	. /etc/profile
endif
endif
ifeq ($(OS), Ubuntu)
ifeq (, $(shell which git))
	sudo apt-get install -y git
endif
ifeq (, $(shell which mvn))
	sudo apt-get install -y maven
endif
ifeq (, $(shell which java))
	sudo apt-get install -y openjdk-8-jdk
endif
ifeq (, $(shell which gcc-7))
	sudo apt-get install -y gcc-7 g++-7
	sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 60 \
		 --slave /usr/bin/g++ g++ /usr/bin/g++-7
	sudo update-alternatives --config gcc
endif
ifeq (, $(shell which make))
	sudo apt-get install -y make
endif
ifeq (, $(shell which automake))
	sudo apt-get install -y automake
endif
ifeq (, $(shell which cmake))
	sudo apt-get install -y cmake
endif
ifeq (, $(shell which bison))
	sudo apt-get install -y bison
endif
ifeq (, $(shell which pkg-config))
	sudo apt-get install -y pkg-config
endif
ifeq (, $(shell ldconfig -p | grep libaio))
	sudo apt-get install -y libaio-dev
endif
ifeq (, $(shell ldconfig -p | grep libncurses))
	sudo apt-get install -y libncurses-dev
endif
ifeq (, $(shell ldconfig -p | grep libsasl2))
	sudo apt-get install -y libsasl2-dev
endif
ifeq (, $(shell ldconfig -p | grep libldap))
	sudo apt-get install -y libldap2-dev
endif
ifeq (, $(shell ldconfig -p | grep libssl))
	sudo apt-get install -y libssl-dev
endif
endif
endif

clean:
	rm -rf $(BUILD_DIR)/run

cleanAll:
	rm -rf $(BUILD_DIR)

# long variables

define START_SCRIPT
#!/bin/bash

PROG_NAME=$$0
ACTION=$$1

usage() {
    echo "Usage: $${PROG_NAME} [start | restart | stop]"
    exit 1;
}

if [ $$# -lt 1 ]; then
    usage
fi

start() {
	echo "start gms & dn..."
	$(BUILD_DIR)/run/galaxyengine/u01/mysql/bin/mysqld --defaults-file=$(DN_CONF) -D
	echo "gms and dn are running."

	echo "start cn..."
	$(BUILD_DIR)/run/galaxysql/bin/startup.sh -P asdf1234ghjk5678
	echo "cn is running."

	echo "start cdc..."
	$(BUILD_DIR)/run/galaxycdc/polardbx-binlog.standalone/bin/daemon.sh start
	echo "cdc is running."

	echo "try polardb-x by:"
	echo "mysql -h127.1 -P8527 -upolardbx_root"
}

stop() {
	echo "stop cdc..."
	ps aux | grep "DaemonBootStrap"|grep -v "grep"| awk '{print $$2}'|xargs kill -9
	ps aux | grep "TaskBootStrap"|grep -v "grep"| awk '{print $$2}'|xargs kill -9
	ps aux | grep "DumperBootStrap"|grep -v "grep"| awk '{print $$2}'|xargs kill -9
	echo "cdc is stopped."

	echo "stop cn..."
	ps aux|grep "TddlLauncher"|grep -v "grep"| awk '{print $$2}' | xargs kill -9
	if [ -f "$(BUILD_DIR)/run/galaxysql/bin/tddl.pid" ]; then
		rm $(BUILD_DIR)/run/galaxysql/bin/tddl.pid
	fi
	echo "cn is stopped."

	echo "stop dn & gms..."
	ps aux|grep "$(BUILD_DIR)/run/galaxyengine/u01/mysql/bin/mysqld" |grep -v "grep" | awk '{print $$2}'| xargs kill
	echo "dn & gms are stopped."
}

case "$${ACTION}" in
    start)
        start
    ;;
    stop)
        stop
    ;;
    restart)
        stop
        sleep 1
        start
    ;;
    *)
        usage
    ;;
esac

endef
export START_SCRIPT

define MY_CNF
[mysqld]
socket = $(DN_DATA_DIR)/u01/my3306/run/mysql.sock
datadir = $(DN_DATA_DIR)/u01/my3306/data
tmpdir = $(DN_DATA_DIR)/u01/my3306/tmp
log-bin = $(DN_DATA_DIR)/u01/my3306/mysql/mysql-bin.log
log-bin-index = $(DN_DATA_DIR)/u01/my3306/mysql/mysql-bin.index
# log-error = $(DN_DATA_DIR)/u01/my3306/mysql/master-error.log
relay-log = $(DN_DATA_DIR)/u01/my3306/mysql/slave-relay.log
relay-log-info-file = $(DN_DATA_DIR)/u01/my3306/mysql/slave-relay-log.info
relay-log-index = $(DN_DATA_DIR)/u01/my3306/mysql/slave-relay-log.index
master-info-file = $(DN_DATA_DIR)/u01/my3306/mysql/master.info
slow_query_log_file = $(DN_DATA_DIR)/u01/my3306/mysql/slow_query.log
innodb_data_home_dir = $(DN_DATA_DIR)/u01/my3306/mysql
innodb_log_group_home_dir = $(DN_DATA_DIR)/u01/my3306/mysql

port = 4886
loose_polarx_port = 32886
loose_galaxyx_port = 32886
loose_polarx_max_connections = 5000

loose_server_id = 476984231
loose_cluster-info = 127.0.0.1:14886@1
loose_cluster-id = 5431
loose_enable_gts = 1
loose_innodb_undo_retention=1800



core-file
loose_log_sql_info=1
loose_log_sql_info_index=1
loose_indexstat=1
loose_tablestat=1
default_authentication_plugin=mysql_native_password

# close 5.6 variables for 5.5
binlog_checksum=CRC32
log_bin_use_v1_row_events=on
explicit_defaults_for_timestamp=OFF
binlog_row_image=FULL
binlog_rows_query_log_events=ON
binlog_stmt_cache_size=32768

#innodb
innodb_data_file_path=ibdata1:100M;ibdata2:200M:autoextend
innodb_buffer_pool_instances=8
innodb_log_files_in_group=4
innodb_log_file_size=200M
innodb_log_buffer_size=200M
innodb_flush_log_at_trx_commit=1
#innodb_additional_mem_pool_size=20M #deprecated in 5.6
innodb_max_dirty_pages_pct=60
innodb_io_capacity_max=10000
innodb_io_capacity=6000
innodb_thread_concurrency=64
innodb_read_io_threads=8
innodb_write_io_threads=8
innodb_open_files=615350
innodb_file_per_table=1
innodb_flush_method=O_DIRECT
innodb_change_buffering=none
innodb_adaptive_flushing=1
#innodb_adaptive_flushing_method=keep_average #percona
#innodb_adaptive_hash_index_partitions=1      #percona
#innodb_fast_checksum=1                       #percona
#innodb_lazy_drop_table=0                     #percona
innodb_old_blocks_time=1000
innodb_stats_on_metadata=0
innodb_use_native_aio=1
innodb_lock_wait_timeout=50
innodb_rollback_on_timeout=0
innodb_purge_threads=1
innodb_strict_mode=1
#transaction-isolation=READ-COMMITTED
innodb_disable_sort_file_cache=ON
innodb_lru_scan_depth=2048
innodb_flush_neighbors=0
innodb_sync_array_size=16
innodb_print_all_deadlocks
innodb_checksum_algorithm=CRC32
innodb_max_dirty_pages_pct_lwm=10
innodb_buffer_pool_size=500M

#myisam
concurrent_insert=2
delayed_insert_timeout=300

#replication
slave_type_conversions="ALL_NON_LOSSY"
slave_net_timeout=4
skip-slave-start=OFF
sync_master_info=10000
sync_relay_log_info=1
master_info_repository=TABLE
relay_log_info_repository=TABLE
relay_log_recovery=0
slave_exec_mode=STRICT
#slave_parallel_type=DATABASE
slave_parallel_type=LOGICAL_CLOCK
loose_slave_pr_mode=TABLE
slave-parallel-workers=32

#binlog
server_id=193317851
binlog_cache_size=32K
max_binlog_cache_size=2147483648
loose_consensus_large_trx=ON
max_binlog_size=500M
max_relay_log_size=500M
relay_log_purge=OFF
binlog-format=ROW
sync_binlog=1
sync_relay_log=1
log-slave-updates=0
expire_logs_days=0
rpl_stop_slave_timeout=300
slave_checkpoint_group=1024
slave_checkpoint_period=300
slave_pending_jobs_size_max=1073741824
slave_rows_search_algorithms='TABLE_SCAN,INDEX_SCAN'
slave_sql_verify_checksum=OFF
master_verify_checksum=OFF

# parallel replay
binlog_transaction_dependency_tracking = WRITESET
transaction_write_set_extraction = XXHASH64


#gtid
gtid_mode=OFF
enforce_gtid_consistency=OFF

loose_consensus-io-thread_cnt=8
loose_consensus-worker-thread_cnt=8
loose_consensus_max_delay_index=10000
loose_consensus-election-timeout=10000
loose_consensus_max_packet_size=131072
loose_consensus_max_log_size=20M
loose_consensus_auto_leader_transfer=ON
loose_consensus_log_cache_size=536870912
loose_consensus_prefetch_cache_size=268435456
loose_consensus_prefetch_window_size=100
loose_consensus_auto_reset_match_index=ON
loose_cluster-mts-recover-use-index=ON
loose_async_commit_thread_count=128
loose_replicate-same-server-id=on
loose_commit_lock_done_count=1
loose_binlog_order_commits=OFF
loose_cluster-log-type-node=OFF

#thread pool
# thread_pool_size=32
# thread_pool_stall_limit=30
# thread_pool_oversubscribe=10
# thread_handling=pool-of-threads

#server
default-storage-engine=INNODB
character-set-server=utf8
lower_case_table_names=1
skip-external-locking
open_files_limit=615350
safe-user-create
local-infile=1
sql_mode='NO_ENGINE_SUBSTITUTION'
performance_schema=0


log_slow_admin_statements=1
loose_log_slow_verbosity=full
long_query_time=1
slow_query_log=0
general_log=0
loose_rds_check_core_file_enabled=ON

table_definition_cache=32768
eq_range_index_dive_limit=200
table_open_cache_instances=16
table_open_cache=32768

thread_stack=1024k
binlog_cache_size=32K
net_buffer_length=16384
thread_cache_size=256
read_rnd_buffer_size=128K
sort_buffer_size=256K
join_buffer_size=128K
read_buffer_size=128K

# skip-name-resolve
#skip-ssl
max_connections=36000
max_user_connections=35000
max_connect_errors=65536
max_allowed_packet=1073741824
connect_timeout=8
net_read_timeout=30
net_write_timeout=60
back_log=1024

loose_boost_pk_access=1
log_queries_not_using_indexes=0
log_timestamps=SYSTEM
innodb_read_ahead_threshold=0

loose_io_state=1
loose_use_myfs=0
loose_daemon_memcached_values_delimiter=':;:'
loose_daemon_memcached_option="-t 32 -c 8000 -p15506"

innodb_doublewrite=1
endef
export MY_CNF

define VERSION_PATCH
diff --git a/VERSION b/MYSQL_VERSION
similarity index 100%
rename from VERSION
rename to MYSQL_VERSION
diff --git a/cmake/mysql_version.cmake b/cmake/mysql_version.cmake
index bed6e9f0..b76b7ba4 100644
--- a/cmake/mysql_version.cmake
+++ b/cmake/mysql_version.cmake
@@ -28,17 +28,17 @@ SET(SHARED_LIB_MAJOR_VERSION "21")
 SET(SHARED_LIB_MINOR_VERSION "1")
 SET(PROTOCOL_VERSION "10")

-# Generate "something" to trigger cmake rerun when VERSION changes
+# Generate "something" to trigger cmake rerun when MYSQL_VERSION changes
 CONFIGURE_FILE(
-  $${CMAKE_SOURCE_DIR}/VERSION
+  $${CMAKE_SOURCE_DIR}/MYSQL_VERSION
   $${CMAKE_BINARY_DIR}/VERSION.dep
 )

-# Read value for a variable from VERSION.
+# Read value for a variable from MYSQL_VERSION.

 MACRO(MYSQL_GET_CONFIG_VALUE keyword var)
  IF(NOT $${var})
-   FILE (STRINGS $${CMAKE_SOURCE_DIR}/VERSION str REGEX "^[ ]*$${keyword}=")
+   FILE (STRINGS $${CMAKE_SOURCE_DIR}/MYSQL_VERSION str REGEX "^[ ]*$${keyword}=")
    IF(str)
      STRING(REPLACE "$${keyword}=" "" str $${str})
      STRING(REGEX REPLACE  "[ ].*" ""  str "$${str}")
@@ -59,7 +59,7 @@ MACRO(GET_MYSQL_VERSION)
   IF(NOT DEFINED MAJOR_VERSION OR
      NOT DEFINED MINOR_VERSION OR
      NOT DEFINED PATCH_VERSION)
-    MESSAGE(FATAL_ERROR "VERSION file cannot be parsed.")
+    MESSAGE(FATAL_ERROR "MYSQL_VERSION file cannot be parsed.")
   ENDIF()

   SET(VERSION
@@ -80,7 +80,7 @@ MACRO(GET_MYSQL_VERSION)
   SET(CPACK_PACKAGE_VERSION_PATCH $${PATCH_VERSION})

   IF(WITH_NDBCLUSTER)
-    # Read MySQL Cluster version values from VERSION, these are optional
+    # Read MySQL Cluster version values from MYSQL_VERSION, these are optional
     # as by default MySQL Cluster is using the MySQL Server version
     MYSQL_GET_CONFIG_VALUE("MYSQL_CLUSTER_VERSION_MAJOR" CLUSTER_MAJOR_VERSION)
     MYSQL_GET_CONFIG_VALUE("MYSQL_CLUSTER_VERSION_MINOR" CLUSTER_MINOR_VERSION)
@@ -89,12 +89,12 @@ MACRO(GET_MYSQL_VERSION)

     # Set MySQL Cluster version same as the MySQL Server version
     # unless a specific MySQL Cluster version has been specified
-    # in the VERSION file. This is the version used when creating
+    # in the MYSQL_VERSION file. This is the version used when creating
     # the cluster package names as well as by all the NDB binaries.
     IF(DEFINED CLUSTER_MAJOR_VERSION AND
        DEFINED CLUSTER_MINOR_VERSION AND
        DEFINED CLUSTER_PATCH_VERSION)
-      # Set MySQL Cluster version to the specific version defined in VERSION
+      # Set MySQL Cluster version to the specific version defined in MYSQL_VERSION
       SET(MYSQL_CLUSTER_VERSION "$${CLUSTER_MAJOR_VERSION}")
       SET(MYSQL_CLUSTER_VERSION
         "$${MYSQL_CLUSTER_VERSION}.$${CLUSTER_MINOR_VERSION}")
@@ -106,7 +106,7 @@ MACRO(GET_MYSQL_VERSION)
       ENDIF()
     ELSE()
       # Set MySQL Cluster version to the same as MySQL Server, possibly
-      # overriding the extra version with value specified in VERSION
+      # overriding the extra version with value specified in MYSQL_VERSION
       # This might be used when MySQL Cluster is still released as DMR
       # while MySQL Server is already GA.
       SET(MYSQL_CLUSTER_VERSION
diff --git a/plugin/galaxy/CMakeLists.txt b/plugin/galaxy/CMakeLists.txt.bak
similarity index 100%
rename from plugin/galaxy/CMakeLists.txt
rename to plugin/galaxy/CMakeLists.txt.bak
diff --git a/plugin/performance_point/CMakeLists.txt b/plugin/performance_point/CMakeLists.txt.bak
similarity index 100%
rename from plugin/performance_point/CMakeLists.txt
rename to plugin/performance_point/CMakeLists.txt.bak
diff --git a/sql/mysqld.cc b/sql/mysqld.cc
index 9fe6d12d..eea38fa7 100644
--- a/sql/mysqld.cc
+++ b/sql/mysqld.cc
@@ -869,6 +869,8 @@ bool opt_large_files = sizeof(my_off_t) > 4;
 static bool opt_autocommit;  ///< for --autocommit command-line option
 static get_opt_arg_source source_autocommit;

+
+bool opt_performance_point_enabled = false;
 /*
   Used with --help for detailed option
 */
diff --git a/sql/package/package_cache.cc b/sql/package/package_cache.cc
index 8a81734e..30ec6a08 100644
--- a/sql/package/package_cache.cc
+++ b/sql/package/package_cache.cc
@@ -76,7 +76,7 @@ static const T *find_package_element(const std::string &schema_name,
   return Package::instance()->lookup_element<T>(schema_name, element_name);
 }
 /* Template instantiation */
-template static const Proc *find_package_element(
+template const Proc *find_package_element(
     const std::string &schema_name, const std::string &element_name);

 /**
endef

export VERSION_PATCH
