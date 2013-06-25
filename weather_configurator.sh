#!/bin/bash 

#
# GLOBAL VARIABLES
#

dbuser=root
dbpass=pelnourmous69
dbcacti=cacti
dbweather=new
overlib="OVERLIBGRAPH  /graph_image.php?rra_id=0&graph_nolegend=true&graph_height=100&graph_width=300&local_graph_id="
#
# FUNCTIONS
#

# db_check - checks that cacti DB is accessible, if not program exits
function db_check {
	local ldbname=$1
	local ldbuser=$2
	local ldbpass=$3
	mysql -u${ldbuser} -p${ldbpass} -e "show tables;" ${ldbname} &>2
	return $?
}

# rand_gen - returns a randomly generated string
function rand_gen {
	echo `< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32}`
}

# host_query returns an array of hosts in WEATHER DB
function get_hosts {
	local host_query="
	SELECT id 
	FROM NODE;"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${host_query}" ${dbweather}`
}

# get_graphdata creates a file in /tmp of graph to data associations
function get_graphdata { 
	local host_id=$1
	local graph_list=/tmp/weather-$(rand_gen)
	local graph_query="
	SELECT DISTINCT
	        data_local.host_id,
	        data_template_data.local_data_id,
		inside.local_graph_id,
	        data_template_data.name_cache
	FROM
		(data_local,data_template_data)
	LEFT JOIN
		data_input
	ON
		(data_input.id=data_template_data.data_input_id)
	LEFT JOIN
		data_template
	ON
		(data_local.data_template_id=data_template.id)
	LEFT JOIN
		(SELECT DISTINCT
	               	graph_templates_graph.local_graph_id,
	               	graph_templates_graph.title_cache
	       	FROM
			(graph_local,graph_templates_graph,graph_tree_items)
	       	LEFT JOIN
			graph_templates
		ON
			(graph_local.graph_template_id=graph_templates.id)
		WHERE
			graph_local.id=graph_templates_graph.local_graph_id)
		AS
			inside
	ON
		(data_template_data.name_cache=inside.title_cache)
	WHERE
		data_local.id=data_template_data.local_data_id
	AND
		data_local.host_id=${host_id}
	AND
		inside.local_graph_id
	IS NOT NULL;"
	mysql -N -u${dbuser} -p${dbpass} -e "${graph_query}" ${dbcacti} > ${graph_list}
	echo ${graph_list}
}

# get_hostname - gets the hostname associated with the provided id
function get_hostname {
	local host_id=$1
	local get_hostname_query="
	SELECT
		hostname
	FROM
		host
	WHERE
		host.id=${host_id};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${get_hostname_query}" ${dbcacti}`
}

# get_description - gets the description associated with the provided id
function get_description {
	local host_id=$1
	local get_description_query="
	SELECT
		description
	FROM
		host
	WHERE
		host.id=${host_id};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${get_description_query}" ${dbcacti}`
}

# get_snmp - takesi host id verifies snmp status sets snmp community globally
function get_snmp {
	local host_id=$1
	local snmp_query="
	SELECT
		snmp_community
	FROM
		host
	WHERE 
		host.id=${host_id};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${snmp_query}" ${dbcacti}`
} 


# create_db - creates database and table for position information of created nodes
function create_db {
	local db_name=$1
	local db_create="
	CREATE DATABASE $db_name;"
	local db_table="
	CREATE TABLE
		NODE
	(
		id INT PRIMARY KEY,
		type VARCHAR(10),
		serial VARCHAR(10),
		version VARCHAR(10),
		active VARCHAR(1),
		xcoord INT,
		ycoord INT);"
	if (mysql -N -u${dbuser} -p${dbpass} -e "${db_create}") ; then
		mysql -N -u${dbuser} -p${dbpass} -e "${db_table}" ${db_name}
	fi	
	return $?
}

# db_set_status - changes host|s active or inactive NULL to T | T to F | F to T. once changed from NULL T|F are the only values
function db_set_status {
	local hosts=$@
	for curr_host in ${hosts} ; do
		local stat=( $(db_get_status ${curr_host}) )
		if [[ "${stat}" =~ NULL|F ]] ; then
			stat=T
			local active_update="
			UPDATE
				NODE
			SET
				active='${stat}'
			WHERE
				NODE.id=${curr_host};"
			mysql -N -u${dbuser} -p${dbpass} -e "${active_update}" ${dbweather}
		else if [[ "${stat}" == 'T' ]] ; then 
			stat=F
			local active_update="
			UPDATE
				NODE
			SET
				active='${stat}'
			WHERE
				NODE.id=${curr_host};"
			mysql -N -u${dbuser} -p${dbpass} -e "${active_update}" ${dbweather}
		fi
		fi
	done
}


# db_get_status gets status of nodes and returns T|F|NULL for provided hostid
function db_get_status {
	local host_id=$1
	local get_hoststat_query="
	SELECT
		active
	FROM	
		NODE
	WHERE
		NODE.id=${host_id};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${get_hoststat_query}" ${dbweather}`
}

# sync_db takes all 'UP' cacti hosts and puts them into weather_generator db w/ inactive status and NULL 
function sync_db {
	local db_cacti=$1
	local db_weather=$2
	local cacti_table=host
	local weather_table=NODE
	local db_weather_count=( $(record_count ${db_weather} ${weather_table}) )
	if [ $db_weather_count -eq 0 ] ; then
		local db_copy_query="
		INSERT INTO
			${db_weather}.${weather_table} (id)
		(SELECT 
			${db_cacti}.${cacti_table}.id
		FROM
			${db_cacti}.${cacti_table}
		WHERE
			${db_cacti}.${cacti_table}.status=3);"
		mysql -N -u${dbuser} -p${dbpass} -e "${db_copy_query}" ${db_weather}
	else
		#INCOMPLETE
		echo need to write comparison portion
	fi
}

# set_types_db - takes in a database and table for weatherdb and sets type serial and version for active nodes
function set_types_db {
	local nsm_oid_host=.1.3.6.1.4.1.25066.3.1.1.1.1.0
	local nsm_oid_serial=.1.3.6.1.4.1.25066.3.1.1.1.3.0
	local nsm_oid_version=.1.3.6.1.4.1.25066.3.1.1.1.4.0
	local ds_oid_host=.1.3.6.1.4.1.22267.1.1.1.1.1.0
	local ds_oid_serial=.1.3.6.1.4.1.22267.1.1.1.1.3.0
	local ds_oid_version=.1.3.6.1.4.1.22267.1.1.1.1.4.0
	local sm_oid_host=.1.3.6.1.4.1.25066.6.1.1.1.1.0
	local sm_oid_serial=.1.3.6.1.4.1.25066.6.1.1.1.3.0
	local sm_oid_version=.1.3.6.1.4.1.25066.6.1.1.1.4.0
	for host in $(get_hosts) ; do
	if !(snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${nsm_oid_host} | grep "No\ Such" &>2) ; then
		set_dbval $host type \"NSM\"
		set_dbval $host serial `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${nsm_oid_serial} | cut -s -d" " -f4`
		set_dbval $host version `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${nsm_oid_version} | cut -s -d" " -f4`
	else if !(snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${ds_oid_host} | grep "No\ Such" &>2) ; then
		set_dbval $host type \"DSENTRY\"
		set_dbval $host serial `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${ds_oid_serial} | cut -s -d" " -f4`
		set_dbval $host version `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${ds_oid_version} | cut -s -d" " -f4`
	else if !(snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${sm_oid_host} | grep "No\ Such" &>2) ; then
		set_dbval $host type \"SM5200\"
		set_dbval $host serial `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${sm_oid_serial} | cut -s -d" " -f4`
		set_dbval $host version `snmpget -v2c -c $(get_snmp ${host}) $(get_hostname ${host}) ${sm_oid_version} | cut -s -d" " -f4`
	fi fi fi
	done
}
	
# record_count - returns the number of rows given DB and TABLE
function record_count {
	local db_dbase=$1
	local db_table=$2
	local db_count_query="
	SELECT
		COUNT(*)
	FROM
		${db_table};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${db_count_query}" ${db_dbase}`
}

# get_dbval - takes table  
function get_dbval {
	local db_table=$1
	local db_column=$2
	local where_column=$3
	local value=$4
	local get_query="
	SELECT
		${db_column}
	FROM
		${db_table}
	WHERE
		${db_table}.${where_column}=${value};"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${get_query}" ${dbweather}`
}

# set_dbval - Takes specification of x or y coord Prompts user for coordinate value
function set_dbval {
	local host_id=$1
	local db_property=$2
	local new_value=$3
	local coord_query="
	UPDATE
		NODE
	SET
		${db_property} = ${new_value}
	WHERE
		NODE.id=${host_id};"
	mysql -N -u${dbuser} -p${dbpass} -e "${coord_query}" ${dbweather}
}

function fanhd_count { 
	local host_id=$1
	local device=$2
	local hostfan_query="
	SELECT
		COUNT(*)
	FROM
		graph_templates_graph
	WHERE
		title_cache like '$(get_description ${host_id})%${device}%STATUS';"
	echo `mysql -N -u${dbuser} -p${dbpass} -e "${hostfan_query}" ${dbcacti}`
}

function position_setter {
	local x=300
	local y=-150
	local offset=400
	for i in $(get_dbval NODE id type \'SM5200\') ; do
		set_dbval $i xcoord $x
		set_dbval $i ycoord $y
		x=$(($x+${offset}))	
	done
	for i in $(get_dbval NODE id type \'NSM\') ; do
		set_dbval $i xcoord $x
		set_dbval $i ycoord $y
		x=$(($x+${offset}))	
	done
}

# create_nsmnode - creates all aspects of nsm entitiy
function create_nsmnode {
	local nsm_id=$1
	local host_hostname=( $(get_hostname ${nsm_id}) )
	local host_description=( $(get_description ${nsm_id}) )
	local snmp_community=( $(get_snmp ${nsm_id}) )
	local nsm_graph_datafile=( $(get_graphdata ${nsm_id}) )
	local nsm_hd_num=`grep "NSM\ DRIVE" $nsm_graph_datafile | wc -l`
	local nsm_fan_num=`grep "FAN.*STATUS" $nsm_graph_datafile | wc -l`
	local nsm_retention_data=`grep Retention ${nsm_graph_datafile} | cut -s -f2`
	local nsm_retention_graph=`grep Retention ${nsm_graph_datafile} | cut -s -f3`
	set_nsmnode ${host_hostname} ${host_description} ${snmp_community}
	for (( hd_index=1; hd_index<=${nsm_hd_num}; hd_index++ )) ; do
		local nsm_hd_line=`grep "NSM\ DRIVE\ ${hd_index}" ${nsm_graph_datafile}`
		local nsm_hd_data=`echo ${nsm_hd_line} | cut -d" " -f2`
		local nsm_hd_graph=`echo ${nsm_hd_line} | cut -d" " -f3`
		set_nsmhd ${nsm_id} ${host_description} ${hd_index} ${nsm_hd_graph} ${nsm_hd_data}
	done
	for (( fan_index=0; fan_index<${nsm_fan_num}; fan_index++ )) ; do
		local nsm_fan_line=`grep "FAN\ ${fan_index}" ${nsm_graph_datafile}`
		local nsm_fan_data=`echo ${nsm_fan_line} | cut -d" " -f2`
		local nsm_fan_graph=`echo ${nsm_fan_line} | cut -d" " -f3`
		set_nsmfan ${nsm_id} ${host_description} ${fan_index} ${nsm_fan_graph} ${nsm_fan_data}
	done
}

# set_nsmnode - Starts creation of an NSM
function set_nsmnode {
	local nsmnode_hostname=$1
	local nsmnode_description=$2
	local nsmnode_community=$3
	local nsmnode_node="
	############## ENDURA NSM - ${nsmnode_description} #################\n
	NODE nsm01.ps.lab\n
	        LABELBGCOLOR 233 243 255\n
	        LABEL {node:this:snmp_in_raw}\n
	        TARGET snmp:${nsmnode_community}:${nsmnode_hostname}:1.3.6.1.4.1.25066.3.1.1.1.1.0:in\n
	        LABELFONT 4\n
	        ICON /var/www/html/cacti/images/nsm5200.png\n
	        USESCALE none in\n
	        POSITION 700 300"
	echo -e ${nsmnode_node}
}

# set_nsmhd - prints indexed HD associated with the present host
function set_nsmhd {
	local hd_hostid=$1
	local hd_hostdescription=$2
	local hd_index=$3
	local hd_graph=$4
	local hd_data=$5
	local nsm_hd="
	NODE ${hd_hostdescription}_hd${hd_index}\n
	        LABEL {node:this:inscaletag:}\n
	        LABELOFFSET\n
	        LABELFONT 4\n
	        LABELFONTCOLOR CONTRAST\n
	        INFOURL /graph.php?rra_id=all&local_graph_id=${hd_graph}\n
	        ${overlib}${hd_graph}\n
	        TARGET gauge:/var/www/html/cacti/rra/${hd_hostid}/${hd_data}.rrd:driveStatus:-\n
	        USESCALE NSMRD absolute\n
	        ICON /var/www/html/cacti/images/hd-nsm.png\n
	        LABELBGCOLOR\n
	        LABELOUTLINECOLOR none\n
	        POSITION ${hd_hostdescription} -80 140\n"
	echo -e ${nsm_hd}
}

# set_nsmfan - prints indexed HD associated with the present host
function set_nsmfan {
	local fan_hostid=$1
	local fan_hostdescription=$2
	local fan_index=$3
	local fan_graph=$4
	local fan_data=$5
	local nsm_fan="
	NODE ${fan_hostdescription}_fan${fan_index}\n
	        LABEL {node:this:inscaletag:}\n
	        LABELOFFSET\n
	        LABELFONT 4\n
	        LABELFONTCOLOR CONTRAST\n
	        INFOURL /graph.php?rra_id=all&local_graph_id=${fan_graph}\n
	        ${overlib}${fan_graph}\n
	        TARGET gauge:/var/www/html/cacti/rra/${fan_hostid}/${fan_data}.rrd:driveStatus:-\n
	        USESCALE NSMRD absolute\n
	        ICON /var/www/html/cacti/images/fan-nsm.png\n
	        LABELBGCOLOR\n
	        LABELOUTLINECOLOR none\n
	        POSITION ${fan_hostdescription} -80 140\n"
	echo -e ${nsm_fan}
}

# create_dsnode - is responsible for the creation of the entire DS entity
function create_dsnode {
	local ds_id=$1
	local host_hostname=( $(get_hostname ${ds_id}) )
	local host_description=( $(get_description ${ds_id}) )
	local snmp_community=( $(get_snmp ${ds_id}) )
	local ds_graph_datafile=( $(get_graphdata ${ds_id}) )
	local ds_hd_num=`grep DS\ HD $ds_graph_datafile | wc -l`
	local ds_cpu_num=`grep CPU $ds_graph_datafile | wc -l`
	local ds_retention_data=`grep Retention ${ds_graph_datafile} | cut -s -f2`
	local ds_retention_graph=`grep Retention ${ds_graph_datafile} | cut -s -f3`
	set_dsnode ${host_hostname} ${host_description} ${snmp_community}
	for (( hd_index=1; hd_index<=${ds_hd_num}; hd_index++ )) ; do
		local ds_hd_line=`grep "DS\ HD.*${hd_index}$" ${ds_graph_datafile}`
		local ds_hd_data=`echo ${ds_hd_line} | cut -d" " -f2`
		local ds_hd_graph=`echo ${ds_hd_line} | cut -d" " -f3`
		set_dshd ${ds_id} ${host_description} ${hd_index} ${ds_hd_graph} ${ds_hd_data}
	done
	for (( cpu_index=0; cpu_index<$ds_cpu_num; cpu_index++ )) ; do
		local ds_cpu_line=`grep "CPU${cpu_index}$" ${ds_graph_datafile}`
		local ds_cpu_data=`echo ${ds_cpu_line} | cut -d" " -f2`
		local ds_cpu_graph=`echo ${ds_cpu_line} | cut -d" " -f3`
		set_dscpu ${ds_id} ${host_description} ${cpu_index} ${ds_cpu_graph} ${ds_cpu_data}
	done
	set_dsend ${ds_id} ${host_description} ${ds_retention_data} ${ds_retention_graph}
	echo "############## END DIGITAL SENTRY ${host_description} #################"
}

# set_dsnode - starts the creation of a DS
function set_dsnode {
	local dsnode_hostname=$1
	local dsnode_description=$2
	local dsnode_community=$3
	local dsnode_node="
	############## DIGITAL SENTRY ${dsnode_description} #################\n
	NODE ${dsnode_description}\n
	        LABELBGCOLOR 233 243 255\n
	        LABEL {dsnode:this:snmp_in_raw}\n
	        LABELFONT 4\n
	        TARGET snmp:${dsnode_community}:${dsnode_hostname}:.1.3.6.1.4.1.22267.1.1.1.1.1.0:in\n
	        USESCALE none in\n
	        ICON /var/www/html/cacti/images/dsnode.png\n
	        POSITION $x $y\n"
	echo -e ${dsnode_node}
}

# set_dshd - prints indexed HD associated with the present host
function set_dshd {
	local hd_hostid=$1
	local hd_hostdescription=$2
	local hd_index=$3
	local hd_graph=$4
	local hd_data=$5
	local ds_hd="
	NODE ${hd_hostdescription}"_hdtmp"${hd_index}\n
	        LABEL {node:this:bandwidth_in:%d}C\n
	        LABELOFFSET E\n
	        LABELFONT 4\n
	        LABELFONTCOLOR CONTRAST\n
	        LABELBGCOLOR none\n
	        LABELOUTLINECOLOR none\n
	        INFOURL /graph.php?rra_id=all&local_graph_id=${hd_graph}\n
	        ${overlib}${hd_graph}\n
	        TARGET gauge:/var/www/html/cacti/rra/${hd_hostid}/${hd_data}.rrd:driveTemp:-\n
	        USESCALE HDTMP in\n
	        ICON /var/www/html/cacti/images/hdtmp.png\n
	        POSITION ${hd_hostdescription} $x $y    #-70 75\n"
	echo -e ${ds_hd}
}
	
# set_dscpu - prints indexed CPU usage associated with the present host
function set_dscpu {
	local cpu_hostid=$1
	local cpu_hostdescription=$2
	local cpu_index=$3
	local cpu_graph=$4
	local cpu_data=$5
	local ds_cpu="
	NODE ${cpu_hostdescription}"_cpu"${cpu_index}\n
	        LABEL {node:this:bandwidth_in:%d}%\n
	        LABELOFFSET E\n
	        LABELFONT 4\n
	        LABELFONTCOLOR CONTRAST\n
	        LABELBGCOLOR none\n
	        LABELOUTLINECOLOR none\n
	        INFOURL /graph.php?rra_id=all&local_graph_id=${cpu_graph}\n
	        ${overlib}${cpu_graph}\n
	        TARGET gauge:/var/www/html/cacti/rra/${cpu_hostid}/${cpu_data}.rrd:cpu:-\n
	        USESCALE CPUUSE in\n
	        ICON /var/www/html/cacti/images/cpuuse.png\n
	        POSITION ${cpu_hostdescription} $x $y    #-70 75\n"
	echo -e ${ds_cpu}
}

# set_dsend - Prints DS RETENTION section
function set_dsend {
	local retention_hostid=$1
	local retention_hostdescription=$2
	local retention_data=$3
	local retention_graph=$4
	local ds_retention="
	NODE ${retention_hostdescription}_retention\n
	        LABEL RETENTION: {node:this:bandwidth_in:%d} DAYS\n
	        LABELBGCOLOR 233 243 255\n
	        LABELFONTCOLOR contrast\n
	        LABELFONT 4\n
	        LABELOUTLINECOLOR none\n
	        INFOURL /graph.php?rra_id=all&local_graph_id=${retention_graph}\n
	        ${overlib}${retention_graph}\n
	        TARGET gauge:/var/www/html/cacti/rra/${retention_hostid}/${retention_data}.rrd:DSRetention:-\n
	        USESCALE none in\n
	        POSITION ${retention_hostdescription} 0 235\n"
	echo -e ${ds_retention}
}

# print_header - prints all scale width height info
function print_header {
	local header="
	# Automatically generated by weather_generator\n
	\n
	\n
	WIDTH 1500\n
	HEIGHT 900\n
	HTMLSTYLE overlib\n
	KEYFONT 3\n
	TITLE LAB\n
	TIMEPOS 672 91 Created: %b %d %Y %H:%M:%S\n
	\n
	BGCOLOR 233 243 255\n
	TITLECOLOR 0 0 0\n
	TIMECOLOR 0 0 0\n
	SCALE DEFAULT 0    0    192 192 192\n
	SCALE DEFAULT 0    1    255 255 255\n
	SCALE DEFAULT 1    10   140   0 255\n
	SCALE DEFAULT 10   25    32  32 255\n
	SCALE DEFAULT 25   40     0 192 255\n
	SCALE DEFAULT 40   55     0 240   0\n
	SCALE DEFAULT 55   70   240 240   0\n
	SCALE DEFAULT 70   85   255 192   0\n
	SCALE DEFAULT 85   100  255   0   0\n
	\n
	SET key_hidezero_DEFAULT 1\n
	# THIS SCALE DEFINES DRIVE TEMP\n
	SCALE HDTMP 0    0    192 192 192\n
	SCALE HDTMP 0    1    255 255 255\n
	SCALE HDTMP 10   25    32  32 255\n
	SCALE HDTMP 25   30     0 192 255\n
	SCALE HDTMP 30   40   240 240   0\n
	SCALE HDTMP 40   55   255 192   0\n
	SCALE HDTMP 55   100   255   0   0\n
	# THIS SCALE DEFINES CPU USAGE\n
	SCALE CPUUSE 0    0    192 192 192\n
	SCALE CPUUSE 0   30    32  32 255\n
	SCALE CPUUSE 30   45     0 192 255\n
	SCALE CPUUSE 45   65   240 240   0\n
	SCALE CPUUSE 65   80   255 192   0\n
	SCALE CPUUSE 80   100   255   0   0\n
	# THIS SCALE DEFINES NSM DRIVE STATUS\n
	SCALE NSMRD 0   0 255 0 0 F\n
	SCALE NSMRD 1   1 0 255 0 OK\n
	SCALE NSMRD 2   2 255 255 0 RB \n
	\n
	# End of global section\n
	\n
	\n
	# TEMPLATE-only NODEs:\n
	\n
	# TEMPLATE-only LINKs:\n
	\n
	# regular NODEs:\n
	#"
	echo -e ${header}
}

# print_footer - Last comments in original file 
function print_footer {
	local footer="
	# regular LINKs:\n
	\n
	\n
	# That's All Folks\n"
	echo -e ${footer}
}

#
# MAIN
#

# GETTING CREDENTIALS FROM USER
#echo "Please enter the User Name of the Cacti Database"
#read dbuser
	
#echo "Please enter the Password for the Cacti Database"
#read dbpass
if !(db_check $dbcacti $dbuser $dbpass) ; then
	echo "ERROR COULD NOT CONNECT TO $dbname DB"
	exit 1
fi

$1 $2 $3 $4 $5 $6

#$db_set_status $(get_hosts)
#create_db ${dbweather}
#for i in {1..100} ; do
#mysql -N -u${dbuser} -p${dbpass} -e "insert into NODE values($i,'nodedesc','serial','version','Y',0,NULL)" ${dbweather}
#done
#sync_db cacti ${dbweather}
#set_types_db ${dbweather} NODE
#set_coord 10 xcoord 10
#set_coord 10 ycoord 10
#hrand=( $(rand_gen) )
#hosts=( $(get_hosts $dbuser $dbpass $hrand) )
#print_header
#create_dsnode 7
#create_nsmnode 9
#print_footer
#rm -f /tmp/weather*
#echo "HOSTID	HOSTNAME"
#cat $hosts
#graphdata=( $(get_graphdata $dbuser $dbpass) )
#cat $graphdata
# CREATE DS ENTRY
#hostname=( $(get_hostname 7) )
#echo $hostname
#description=( $(get_description 7) )
#echo $description
