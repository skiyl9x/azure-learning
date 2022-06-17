#!/bin/bash

check_result() {
    if [ $1 -ne 0 ]; then
        echo -e "${RED}[Failed]${NC}"
	echo "  - More details:"
	cat result
	echo ""
    else
	echo -e "${GREEN}[Done]${NC}"
    fi
}

stepMessage() {
    echo -e -n "- $1: "
}


checkDockerSVC() {
    ERRCODE=$1
    if [ $ERRCODE -ne 0 ]; then
        check_result 1
	echo -n "  - Restoring docker.service configuration: "
	( cp $DOCKER_SVC_FILE"_old" $DOCKER_SVC_FILE && 
		rm -f $DOCKER_SVC_FILE"_old" ) > result 2>&1
	check_result $?
    else
        check_result 0
    fi
}
TARGETDIR=/etc/docker/certs
mkdir -p $TARGETDIR
PASSWORD='pass'
HOST=$(hostname -f)
CASUBJSTRING="/C=GB/ST=London/L=London/O=ExampleCompany/OU=IT/CN=example.com/emailAddress=test@example.com"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
CYAN='\033[0;36m'
PORT=2375
DOCKER_SVC_FILE="/lib/systemd/system/docker.service"
EXPIRATIONDAYS=265


stepMessage "Generating CA private key"
openssl genrsa -aes256 -passout pass:$PASSWORD -out $TARGETDIR/ca-key.pem 4096 > result 2>&1
check_result $?

stepMessage "Generating CA public key"
openssl req -new -x509 -days $EXPIRATIONDAYS -passin pass:$PASSWORD -key $TARGETDIR/ca-key.pem -sha256 -out $TARGETDIR/ca.pem -subj $CASUBJSTRING > result 2>&1
check_result $?


stepMessage "Creating server key"
openssl genrsa -out $TARGETDIR/server-key.pem 4096 > result 2>&1
check_result $?


stepMessage "Creating certificate signing request (CSR)"
openssl req -subj $CASUBJSTRING -sha256 -new -key $TARGETDIR/server-key.pem -out $TARGETDIR/server.csr > result 2>&1
check_result $?

stepMessage "Generating extfile.cnf"
(cat /dev/null > $TARGETDIR/extfile.cnf && IP=$(curl ifconfig.co) &&
echo subjectAltName = DNS:$HOST,IP:$IP,IP:127.0.0.1 >> $TARGETDIR/extfile.cnf &&
echo extendedKeyUsage = serverAuth >> $TARGETDIR/extfile.cnf ) > result 2>&1
check_result $?


stepMessage "Generating signed certificate"
openssl x509 -passin pass:$PASSWORD -req -days $EXPIRATIONDAYS -in $TARGETDIR/server.csr -CA $TARGETDIR/ca.pem -CAkey $TARGETDIR/ca-key.pem -CAcreateserial -out $TARGETDIR/server-cert.pem -extfile $TARGETDIR/extfile.cnf > result 2>&1
check_result $?

stepMessage "Generating key.pem for client key.pem"
openssl genrsa -out $TARGETDIR/client-key.pem 4096 > result 2>&1
check_result $?

stepMessage "Generating client.csr"
openssl req -subj '/CN=client' -new -key $TARGETDIR/client-key.pem -out $TARGETDIR/client.csr > result 2>&1
check_result $?

stepMessage "Generating signed sertificate for client"
(echo extendedKeyUsage = clientAuth > $TARGETDIR/extfile-client.cnf &&
openssl x509 -req -days $EXPIRATIONDAYS -passin pass:$PASSWORD -sha256 -in $TARGETDIR/client.csr -CA $TARGETDIR/ca.pem -CAkey $TARGETDIR/ca-key.pem \
	-CAcreateserial -out $TARGETDIR/client-cert.pem -extfile $TARGETDIR/extfile-client.cnf) > result 2>&1
check_result $?

stepMessage "Removing files client.csr server.csr extfile.cnf extfile-client.cnf"
rm -v $TARGETDIR/client.csr $TARGETDIR/server.csr $TARGETDIR/extfile.cnf $TARGETDIR/extfile-client.cnf > result 2>&1
check_result $?

stepMessage "Changing rights for files"
( chmod -v 0400 $TARGETDIR/ca-key.pem $TARGETDIR/client-key.pem $TARGETDIR/server-key.pem &&
	chmod -v 0444 $TARGETDIR/ca.pem $TARGETDIR/server-cert.pem $TARGETDIR/client-cert.pem ) > result 2>&1
check_result $?

stepMessage "Changing docker.service file"
( cp $DOCKER_SVC_FILE $DOCKER_SVC_FILE"_old" &&
	sed -i "s~ExecStart=.*~ExecStart=\/usr\/bin/dockerd --tlsverify --tlscacert=$TARGETDIR\/ca.pem --tlscert=$TARGETDIR\/server-cert.pem  --tlskey=$TARGETDIR\/server-key.pem -H fd:\/\/ -H=tcp:\/\/0.0.0.0:$PORT --containerd=\/run\/containerd\/containerd.sock~" $DOCKER_SVC_FILE ) > result 2>&1
checkDockerSVC $?

stepMessage "Applying service configuration"
systemctl daemon-reload > result 2>&1
check_result $?

stepMessage "Restarting docker.service"
systemctl restart docker > result 2>&1
checkDockerSVC $?

stepMessage "Check if docker is available through port $PORT"
docker --tlsverify --tlscacert=$TARGETDIR/ca.pem --tlscert=$TARGETDIR/client-cert.pem --tlskey=$TARGETDIR/client-key.pem -H=$HOST:2375 version > result 2>&1
check_result $?

echo -e "\nIn order to get access to the docker use this command:
docker --tlsverify --tlscacert=$TARGETDIR/ca.pem --tlscert=$TARGETDIR/client-cert.pem --tlskey=$TARGETDIR/client-key.pem -H=$HOST:2375 version
"
