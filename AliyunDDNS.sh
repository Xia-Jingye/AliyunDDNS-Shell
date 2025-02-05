#!/bin/sh

set -e

export BASE_PWD="$(dirname "$0")"
Ali_API="https://alidns.aliyuncs.com/"

__check_tool() {
    local tool="$1"
    which "$tool" >/dev/null 2>&1 || { echo "$tool is not installed"; return 1; }
    return 0
}

__ali_urlencode() {
  local _str="$1"
  local _str_len=${#_str}
  local _u_i=1
  while [ "$_u_i" -le "$_str_len" ]; do
    local _str_c="$(printf "%s" "$_str" | cut -c "$_u_i")"
    case $_str_c in [a-zA-Z0-9.~_-])
      printf "%s" "$_str_c"
      ;;
    *)
      printf "%%%02X" "'$_str_c"
      ;;
    esac
    local _u_i="$(expr "${_u_i}" + 1)"
  done
}

__ali_nonce() {
  date +"%s%N"
}

__timestamp() {
  date -u +"%Y-%m-%dT%H%%3A%M%%3A%SZ"
}

__ali_signature() {
    local secret="$1"
    echo -n "GET&%2F&$(__ali_urlencode "$2")" | openssl dgst -sha1 -hmac "$secret&" -binary | openssl base64 -A
}

__get_dns_record() {
    local key_id="$1"
    local secret="$2"
    local dmn="$3"
    local rr="$4"
    local type="$5"
    local query="AccessKeyId=${key_id}"
    query=$query'&Action=DescribeDomainRecords'
    query=$query'&DomainName='${dmn}
    query=$query'&Format=json'
    query=$query"&RRKeyWord=$(__ali_urlencode "$rr")"
    query=$query'&SignatureMethod=HMAC-SHA1'
    query=$query"&SignatureNonce=$(__ali_nonce)"
    query=$query'&SignatureVersion=1.0'
    query=$query'&Timestamp='$(__timestamp)
    query=$query'&TypeKeyWord='${type}
    query=$query'&Version=2015-01-09'
    local signature="$(__ali_signature "$secret" "$query")"
    local url="$Ali_API?$query&Signature=$(__ali_urlencode "$signature")"
    lib_curl "$url"
    return $?
}

__insert_dns_record() {
    local key_id="$1"
    local secret="$2"
    local dmn="$3"
    local rr="$4"
    local type="$5"
    local val="$6"
    local query="AccessKeyId=${key_id}"
    query=$query'&Action=AddDomainRecord'
    query=$query'&DomainName='${dmn}
    query=$query'&Format=json'
    query=$query"&RR=$(__ali_urlencode "$rr")"
    query=$query'&SignatureMethod=HMAC-SHA1'
    query=$query"&SignatureNonce=$(__ali_nonce)"
    query=$query'&SignatureVersion=1.0'
    query=$query'&Timestamp='$(__timestamp)
    query=$query'&Type='${type}
    query=$query'&Value='$(__ali_urlencode "${val}")
    query=$query'&Version=2015-01-09'
    local signature="$(__ali_signature "$secret" "$query")"
    local url="$Ali_API?$query&Signature=$(__ali_urlencode "$signature")"
    lib_curl "$url"
    return $?
}

__update_dns_record() {
    local key_id="$1"
    local secret="$2"
    local dmn="$3"
    local rr="$4"
    local type="$5"
    local val="$6"
    local recid="$7"
    local query="AccessKeyId=${key_id}"
    query=$query'&Action=UpdateDomainRecord'
    query=$query'&DomainName='${dmn}
    query=$query'&Format=json'
    query=$query"&RR=$(__ali_urlencode "$rr")"
    query=$query'&RecordId='${recid}
    query=$query'&SignatureMethod=HMAC-SHA1'
    query=$query"&SignatureNonce=$(__ali_nonce)"
    query=$query'&SignatureVersion=1.0'
    query=$query'&Timestamp='$(__timestamp)
    query=$query'&Type='${type}
    query=$query'&Value='$(__ali_urlencode "${val}")
    query=$query'&Version=2015-01-09'
    local signature="$(__ali_signature "$secret" "$query")"
    local url="$Ali_API?$query&Signature=$(__ali_urlencode "$signature")"
    lib_curl "$url"
    return $?
}

__exec_plugins() {
    local plugin_file
    for plugin_file in "${BASE_PWD}/plugins/"*.sh; do
        local plugin_base_name="$(basename "$plugin_file")"
        local plugin_name=${plugin_base_name%%.*}
        if eval [ \"\$"p_${plugin_name}_enable"\" = \"1\" ]; then
            "$plugin_file" "$@"
        fi
    done
}

. "${BASE_PWD}/AliyunDDNS.env"
. "${BASE_PWD}/lib/common.sh"

__check_tool "openssl"
web_tool=""
if which curl >/dev/null 2>&1; then
    web_tool="curl -s"
fi
if [ -z "$web_tool" ]; then
    if which wget >/dev/null 2>&1; then
        web_tool="wget -O - -q"
    fi
fi
if [ -z "$web_tool" ]; then
    echo "curl or wget must be installed"
    exit 1
fi

lib_check_parm "access_key_id"
lib_check_parm "access_key_secret"
lib_check_parm "domain_name"
lib_check_parm "host_record"
lib_check_parm "ip_api_url"

dns_type="A"
if [ "$use_ipv6" = "1" ]; then
    dns_type="$dns_type AAAA"
fi

for iptype in $dns_type; do
    if [ "$iptype" = "A" ]; then
        ip="$(lib_curl -4 "$ip_api_url")"
        if [ $? != 0 ] || [ -z "$ip" ]; then
            echo "get ipv4 address failed"
            continue
        fi
        echo "handle ipv4..."
    else
        ip="$(lib_curl -6 "$ip_api_url")"
        if [ $? != 0 ] || [ -z "$ip" ]; then
            echo "get ipv6 address failed"
            continue
        fi
        echo "handle ipv6..."
    fi
    respon="$(__get_dns_record "${access_key_id}" "${access_key_secret}" "${domain_name}" "${host_record}" "$iptype")"
    dns_record_id="$(lib_json_value "$respon" "RecordId" "string")"
    dns_value="$(lib_json_value "$respon" "Value" "string")"
    if [ -z "$dns_record_id" ] || [ -z "$dns_value" ]; then
        echo "insert dns record"
        __insert_dns_record "${access_key_id}" "${access_key_secret}" "${domain_name}" "${host_record}" "$iptype" "$ip"
        echo ""
        __exec_plugins "1" "${iptype}" "${domain_name}" "${host_record}" "" "$ip"
    else
        if [ "$dns_value" != "$ip" ]; then
            echo "update dns record"
            __update_dns_record "${access_key_id}" "${access_key_secret}" "${domain_name}" "${host_record}" "$iptype" "$ip" "$dns_record_id"
            echo ""
            __exec_plugins "2" "${iptype}" "${domain_name}" "${host_record}" "$dns_value" "$ip"
        fi
    fi
done

title='路由器IP推送'
content=`ifconfig -a | grep inet | grep -v inet6 | grep -v 127.0.0.1 | grep -v 192.168.1.1 | awk '{print $2}' | tr -d "addr:"`
corpid=''
corpsecret=''
agentid=''
access_token='/tmp/access_token.cache'
access_token_expires_time='/tmp/access_token_expires_time.cache'
post='{"touser":"@all", "toparty":"@all", "totag":"@all", "msgtype":"text", "agentid":'${agentid}', "text":{"content":"'${content}'"}}'

if [ ! -s "/tmp/ip.cache" ]; then
	touch /tmp/ip.cache
	ip_cache=`cat /tmp/ip.cache`
else
	ip_cache=`cat /tmp/ip.cache`
fi

if [ -z "${corpid}" ] || [ -z "${corpsecret}" ] || [ -z "${agentid}" ]; then
	exit 0
fi

if [ -z "${dns_record_id}" ] || [ -z "${dns_value}" ] || [ "${dns_value}" != "${ip}" ] || [ "${ip}" != "${ip_cache}" ]; then
	if [ -s "${access_token}" ] && [ -s "${access_token_expires_time}" ]; then
		echo '检测access_token'
		access_token_expires_time_num=$(cat ${access_token_expires_time})
		if [ "$(date +%s)" -gt "${access_token_expires_time_num}" ]; then
			echo 'access_token失效'
			serverinfo=$(curl -s "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=${corpid}&corpsecret=${corpsecret}")
			servererrmsg=$(echo ${serverinfo} | sed 's/,/\n/g' | grep "errmsg" | sed 's/:/\n/g' | sed '1d' | sed 's/"//g' | sed 's/}//g')
			if [ "${servererrmsg}" = ok ]; then
				echo `expr $(date +%s) + 7200` > ${access_token_expires_time}
				echo ${serverinfo} | sed 's/,/\n/g' | grep "access_token" | sed 's/:/\n/g' | sed '1d' | sed 's/"//g' > ${access_token}
				echo 'access_token获取成功，返回信息：'${servererrmsg}''
			else
				echo 'access_token获取失败，返回信息：'${servererrmsg}''
				exit 0
			fi
		else
			echo 'access_token有效'
		fi
	else
		echo '获取access_token'
		serverinfo=$(curl -s "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=${corpid}&corpsecret=${corpsecret}")
		servererrmsg=$(echo ${serverinfo} | sed 's/,/\n/g' | grep "errmsg" | sed 's/:/\n/g' | sed '1d' | sed 's/"//g' | sed 's/}//g')
		if [ "${servererrmsg}" = ok ]; then
			echo `expr $(date +%s) + 7200` > ${access_token_expires_time}
			echo ${serverinfo} | sed 's/,/\n/g' | grep "access_token" | sed 's/:/\n/g' | sed '1d' | sed 's/"//g' > ${access_token}
			echo 'access_token获取成功，返回信息：'${servererrmsg}''
		else
			echo 'access_token获取失败，返回信息：'${servererrmsg}''
			exit 0
		fi
	fi
	access_token_in_url=`cat ${access_token}`
	sendinfo=$(curl -s -d "${post}" https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=${access_token_in_url})
	senderrmsg=$(echo ${sendinfo} | sed 's/,/\n/g' | grep "errmsg" | sed 's/:/\n/g' | sed '1d' | sed 's/"//g' | sed 's/}//g')
	if [ "${senderrmsg}" = ok ]; then
		sed -i '/AliyunDDNS/d' /etc/crontabs/root
		echo "0 0 * * * /etc/AliyunDDNS.sh" >> /etc/crontabs/root
		crontab /etc/crontabs/root
		echo ${content} > /tmp/ip.cache
		echo '信息发送成功，返回信息：'${senderrmsg}''
	else
		echo '信息发送失败，返回信息：'${senderrmsg}''
		exit 0
	fi
else
	echo '没什么要推送的'
	exit 0
fi
