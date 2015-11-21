#!/bin/bash

##############################
# dnspodsh v0.4
# 基于dnspod api构架的bash ddns客户端
# 修改者：guisu2010@gmail.com
# 原作者：zrong(zengrong.net)
# 详细介绍：http://zengrong.net/post/1524.htm
# 创建日期：2012-02-13
# 更新日期：2015-05-15
##############################

login_token=""
login_email=''
login_password=''
format="json"
lang="cn"
userAgent="dnspodsh/0.4(guisu2010@gmail.com)"
if [ -n $login_token ];then
	commonPost="login_token=$login_token&format=$format&lang=$lang"
else
	commonPost="login_email=$login_email&login_password=$login_password&format=$format&lang=$lang"
fi

apiUrl='https://dnsapi.cn/'
ipUrl='http://members.3322.org/dyndns/getip'

# 要处理的域名数组，每个元素代表一个域名的一组记录
# 在数组的一个元素中，以空格分隔域名和子域名
# 第一个空格前为主域名，后面用空格分离多个子域名
# 如果使用泛域名，必须用\*转义
#domainList[0]='domain1.com \* @ www'
#domainList[1]='domain2.com subdomain subdomain2'

# 这里是只修改一个子域名的例子
domainList[0]='example.com subdomain'

# 多长时间比较一次ip地址
delay=300

# logfile
logDir='/var/log'
logFile=$logDir'/dnspodsh.log'
traceFile=$logDir'/dnspodshtrace.log'

# 检测ip地址是否符合要求
checkip()
{
	# ipv4地址
	if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]];then
		return 0
	# ipv6地址
	elif [[ "$1" =~ ^([\da-fA-F]{1,4}:){7}[\da-fA-F]{1,4}$|^:((:[\da-fA-F]{1,4}){1,6}|:)$|^[\da-fA-F]{1,4}:((:[\da-fA-F]{1,4}){1,5}|:)$|^([\da-fA-F]{1,4}:){2}((:[\da-fA-F]{1,4}){1,4}|:)$|^([\da-fA-F]{1,4}:){3}((:[\da-fA-F]{1,4}){1,3}|:)$|^([\da-fA-F]{1,4}:){4}((:[\da-fA-F]{1,4}){1,2}|:)$|^([\da-fA-F]{1,4}:){5}:([\da-fA-F]{1,4})?$|^([\da-fA-F]{1,4}:){6}:$ ]];then
		return 0
	fi
	return 1
}

getUrl()
{
	#curl -s -A $userAgent -d $commonPost$2 --trace $traceFile $apiUrl$1
	curl -s -A $userAgent -d $commonPost$2 $apiUrl$1
}

getVersion()
{
	getUrl "Info.Version"
}

getUserDetail()
{
	getUrl "User.Detail"
}

writeLog()
{
	if [ -w $logDir ];then
		local pre=`date`
		for arg in $@;do
			pre=$pre'\t'$arg
		done
		echo -e $pre>>$logFile
	fi
	echo -e $1
}

getDomainList()
{
	getUrl "Domain.List" "&type=all&offset=0&length=10"
}

# 根据域名id获取记录列表
# $1 域名id
getRecordList()
{
	getUrl "Record.List" "&domain_id=$1&offset=0&length=20"
}

# 设置记录
setRecord()
{
	writeLog "set domain $3.$8 to new ip:$7"
	local subDomain=$3
	# 由于*会被扩展，在最后一步将转义的\*替换成*
	if [ "$subDomain" = '\*' ];then
		subDomain='*'
	fi
	local request="&domain_id=$1&record_id=$2&sub_domain=$subDomain&record_type=$4&record_line=$5&ttl=$6&value=$7"
	#echo $request
	local saveResult=$(getUrl 'Record.Modify' "$request")
	# 检测返回是否正常，但即使不正常也不退出程序
	if checkStatusCode "$saveResult" 0;then
		writeLog "set record $3.$8 success."
	fi
	#getUrl 'Record.Modify' "&domain_id=$domainid&record_id=$recordid&sub_domain=$recordName&record_type=$recordtype&record_line=$recordline&ttl=$recordttl&value=$newip"
}

# 设置一批记录
setRecords()
{
	numRecord=${#changedRecords[@]}
	for (( i=0; i < $numRecord; i++ ));do
		setRecord ${changedRecords[$i]}
	done
	# 删除待处理的变量
	unset changeRecords
}

# 通过key得到找到一个JSON对象字符串中的值
getDataByKey()
{
	local s='s/{[^}]*"'$2'":["]*\('$(getRegexp $2)'\)["]*[^}]*}/\1/'
	#echo '拼合成的regexp:'$s
	echo $1|sed $s
}

# 根据key返回要获取的正则表达式
getRegexp()
{
	case $1 in
		'value') echo '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}';;
		'type') echo '[A-Z]\+';;
		'name') echo '[-_.A-Za-z*]\+';;
		'ttl'|'id') echo '[0-9]\+';;
		'line') echo '[^"]\+';;
	esac
}

# 通过一个JSON key名称，获取一个{}包围的JSON对象字符串
# $1 要搜索的key名称
# $2 要搜索的对应值
getJSONObjByKey()
{
	grep -o '{[^}{]*"'$1'":"'$2'"[^}]*}'
}

# 获取A记录类型的域名信息
# 对于其它记录，同样的名称可以对应多条记录，因此使用getJSONObjByKey可能获取不到需要的数据
getJSONObjByARecord()
{
	grep -o '{[^}{]*"name":"'$1'"[^}]*"type":"A"[^}]*}'
}

# 获取返回代码是否正确
# $1 要检测的字符串，该字符串包含{status:{code:1}}形式，代表DNSPodAPI返回正确
# $2 是否要停止程序，因为dnspod在代码错误过多的情况下会封禁账号
checkStatusCode()
{
	if [[ "$1" =~ \{\"status\":\{[^}{]*\"code\":\"1\"[^}]*\} ]];then
		return 0
	fi
	writeLog "DNSPOD return error:$1"
	# 根据参数需求退出程序
	if [ -n "$2" ] && [ "$2" -eq 1 ];then
		writeLog 'exit dnspodsh'
		exit 1
	fi
}

# 获取与当前ip不同的，要更新的记录的数组
getChangedRecords()
{
	# 从DNSPod获取最新的域名列表
	local domainListInfo=$(getDomainList)
	if [ -z "$domainListInfo" ];then
		writeLog 'DNSPOD tell me domain list is null,waiting...'
		return 1
	fi
	checkStatusCode "$domainListInfo" 1

	# 主域名的id
	local domainid
	local domainName
	# 主域名的JSON信息
	local domainInfo
	# 主域名的所有记录列表
	local recordList
	# 一条记录的JSON信息
	local recordInfo
	# 记录的id
	local recordid
	local recordName
	# 记录的TTL
	local recordTtl
	# 记录的类型
	local recordType
	# 记录的线路
	local recordLine
	local j

	# 用于记录被改变的记录
	unset changedRecords

	local numDomain=${#domainList[@]}
	local domainGroup

	for ((i=0;i<$numDomain;i++));do
		domainGroup=${domainList[$i]}
		j=0
		for domain in ${domainGroup[@]};do
			# 列表的第一个项目，是主域名
			if ((j==0));then
				domainName=$domain
				domainInfo=$(echo $domainListInfo|getJSONObjByKey 'name' $domainName) 
				domainid=$(getDataByKey "$domainInfo" 'id')
				recordList=$(getRecordList $domainid)
				if [ -z "$recordList" ];then
					writeLog 'DNSPOD tell me record list null,waiting...'
					return 1
				fi
				checkStatusCode "$recordList" 1
			else
				# 从dnspod获取要设置的子域名记录的信息
				recordInfo=$(echo $recordList|getJSONObjByARecord $domain)
				# 如果取不到记录，则不处理
				if [ -z "$recordInfo" ];then
					continue
				fi

				# 从dnspod获取要设置的子域名的ip
				oldip=$(getDataByKey "$recordInfo" 'value')

				# 检测获取到的旧ip地址是否符合ip规则
				if ! checkip "$oldip";then
					writeLog 'get old ip error!it is "$oldid".waiting...'
					continue
				fi

				if [ "$newip" != "$oldip" ];then
					recordid=$(getDataByKey "$recordInfo" 'id')
					recordName=$(getDataByKey "$recordInfo" 'name')
					recordTtl=$(getDataByKey "$recordInfo" 'ttl')
					recordType=$(getDataByKey "$recordInfo" 'type')
					# 由于从服务器获取的线路是utf编码，目前无法知道如何转换成中文，因此在这里写死。dnspod中免费用户的默认线路的名称就是“默认”
					#recordLine=$(getDataByKey "$recordInfo" 'line')
					recordLine='默认'
					# 判断取值是否正常，如果值为空就不处理
					if [ -n "$recordid" ] && [ -n "$recordTtl" ] && [ -n "$recordType" ]; then
						# 使用数组记录需要修改的子域名的所有值
						# 这里一共有8个参数，与setRecord中的参数对应
						changedRecords[${#changedRecords[@]}]="$domainid $recordid $domain $recordType $recordLine $recordTtl $newip $domainName"
					fi
				fi
			fi
			j=$((j+1))
		done
	done
}

# 执行检测工作
go()
{
	# 由于获取到的数据多了一些多余的字符，所以提取ip地址的部分
	# 从api中获取当前的外网ip
	# newip=$(curl -s $ipUrl|grep -o $(getRegexp 'value'))
	newip=`/sbin/ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v 192.168|grep -v inet6|awk '{print $2}'|tr -d "addr:"`
	# 如果获取最新ip错误，就继续等待下一次取值
	if ! checkip "$newip";then
		writeLog 'can not get new ip,waiting...'
		sleep $delay
		continue
	fi
	echo 'wan ip:'$newip
	echo $commonPost
	# 获取需要修改的记录
	getChangedRecords
	if (( ${#changedRecords[@]} > 0 ));then
		writeLog "ip is changed,new ip is:$newip"
		setRecords
	fi
}

while [ 1 ];do
	go
	sleep $delay
done
