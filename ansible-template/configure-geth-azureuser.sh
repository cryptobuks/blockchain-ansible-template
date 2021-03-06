#!/bin/bash

# Utility function to exit with message
unsuccessful_exit()
{
  echo "FATAL: Exiting script due to: $1, error code: $2";
  exit $2;
}

echo "===== Initializing geth installation =====";
date;

############
# Parameters
############
# Validate that all arguments are supplied
if [ $# -lt 10 ]; then unsuccessful_exit "Insufficient parameters supplied." 28; fi

AZUREUSER=$1;
PASSWD=$2;
PASSPHRASE=$3;
ARTIFACTS_URL_PREFIX=$4;
NETWORK_ID=$5;
MAX_PEERS=$6;
NODE_TYPE=$7;       # (0=Transaction node; 1=Mining node )
GETH_IPC_PORT=$8;
NUM_BOOT_NODES=$9;
NUM_MN_NODES=${10};
MN_NODE_PREFIX=${11};
SPECIFIED_GENESIS_BLOCK=${12};
MN_NODE_SEQNUM=${13};   #Only supplied for NODE_TYPE=1
NUM_TX_NODES=${13};     #Only supplied for NODE_TYPE=0
TX_NODE_PREFIX=${14};   #Only supplied for NODE_TYPE=0
ADMIN_SITE_PORT=${15};  #Only supplied for NODE_TYPE=0

MINER_THREADS=1;
# Difficulty constant represents ~15 sec. block generation for one node
DIFFICULTY_CONSTANT="0x3333";

HOMEDIR="/home/$AZUREUSER";
VMNAME=`hostname`;
GETH_HOME="$HOMEDIR/.ethereum";
mkdir -p $GETH_HOME;
ETHERADMIN_HOME="$HOMEDIR/etheradmin";
GETH_LOG_FILE_PATH="$HOMEDIR/geth.log";
GENESIS_FILE_PATH="$HOMEDIR/genesis.json";
GETH_CFG_FILE_PATH="$HOMEDIR/geth.cfg";
NODEKEY_FILE_PATH="$GETH_HOME/nodekey";

##################
# Scale difficulty
##################
# Target difficulty scales with number of miners
DIFFICULTY=`printf "0x%X" $(($DIFFICULTY_CONSTANT * $NUM_MN_NODES))`;


################
# Update modules
################
echo "===== Starting packages update =====";
sudo apt-get -y update || unsuccessful_exit "Error starting packages update
" 29;
echo "===== Completed packages update =====";
# To avoid intermittent issues with package DB staying locked when next apt-get runs
sleep 5;

##################
# Install packages
##################
echo "===== Starting packages installation =====";
sudo apt-get -y install npm=3.5.2-0ubuntu4 git=1:2.7.4-0ubuntu1 jq=1.5+dfsg-1 || unsuccessful_exit "package install 1 failed" 32;
sudo update-alternatives --install /usr/bin/node nodejs /usr/bin/nodejs 100 || unsuccessful_exit "package install 2 failed" 2;
echo "===== Completed packages installation =====";

##############
# Install geth
##############
echo "===== Starting geth installation =====";
wget https://gethstore.blob.core.windows.net/builds/geth-alltools-linux-amd64-1.7.3-4bb3c89d.tar.gz || unsuccessful_exit "geth download failed"
 3;
wget https://gethstore.blob.core.windows.net/builds/geth-alltools-linux-amd64-1.7.3-4bb3c89d.tar.gz.asc || unsuccessful_exit "geth signature download failed"
 4;

# Import geth buildserver keys
gpg --recv-keys --keyserver hkp://keyserver.ubuntu.com F9585DE6 C2FF8BBF 9BA28146 7B9E2481 D2A67EAC || unsuccessful_exit "import geth buildserver keys failed" 5;

# Validate signature
gpg --verify geth-alltools-linux-amd64-1.7.3-4bb3c89d.tar.gz.asc || unsuccessful_exit "validate geth download failed" 6;

# Unpack archive
tar xzf geth-alltools-linux-amd64-1.7.3-4bb3c89d.tar.gz || unsuccessful_exit "geth download unpack failed" 7;

# /usr/bin is in $PATH by default, we'll put our binaries there
sudo cp geth-alltools-linux-amd64-1.7.3-4bb3c89d/* /usr/bin/ || unsuccessful_exit "copy of geth to /usr/bin failed" 8;
echo "===== Completed geth installation =====";

#############
# Build node keys and node IDs
#############
echo "===== Starting node key and node ID generation =====";
declare -a NODE_KEYS
declare -a NODE_IDS
for i in `seq 0 $(($NUM_BOOT_NODES - 1))`; do
	BOOT_NODE_HOSTNAME=$MN_NODE_PREFIX$i;
	NODE_KEYS[$i]=`echo $BOOT_NODE_HOSTNAME | sha256sum | cut -d ' ' -f 1`;
	setsid bootnode --nodekeyhex ${NODE_KEYS[$i]} > $HOMEDIR/tempbootnodeoutput 2>&1 &
	while sleep 10; do
		if [ -s $HOMEDIR/tempbootnodeoutput ]; then
			killall bootnode || unsuccessful_exit "failed to kill all bootnode processes" 9;
			NODE_IDS[$i]=`grep -Po '(?<=\/\/).*(?=@)' -m 1 $HOMEDIR/tempbootnodeoutput`;
			rm $HOMEDIR/tempbootnodeoutput || unsuccessful_exit "failed to remove tempbootnodeoutput file" 10;
			# This sleep allows for geth's graceful exit.
			sleep 5;
			break;
		fi
	done
done

##################################
# Check for empty node keys or IDs
##################################
for nodekey in "${NODE_KEYS[@]}"; do
	if [ -z $nodekey ]; then
		unsuccessful_exit "empty node key detected" 11;
	fi
done
for nodeid in "${NODE_IDS[@]}"; do
	if [ -z $nodeid ]; then
		unsuccessful_exit "empty node ID detected" 12;
	fi
done

echo "===== Completed node key and node ID generation =====";

echo "===== Starting genesis file =====";

##############################################
# Generate private key and import into geth
##############################################

PASSWD_FILE="$GETH_HOME/passwd.info";
printf %s $PASSWD > $PASSWD_FILE;

PRIV_KEY=`echo "$PASSPHRASE" | sha256sum | sed s/-// | sed "s/ //"`;
printf "%s" $PRIV_KEY > $HOMEDIR/priv_genesis.key;
ETHERBASE_ADDRESS=`geth --datadir $GETH_HOME --password $PASSWD_FILE account import $HOMEDIR/priv_genesis.key | grep -oP '\{\K[^}]+'` || unsuccessful_exit "failed to import pre-fund account" 13;

if [ -z $ETHERBASE_ADDRESS ]; then unsuccessful_exit "could not determine address of etherbase account after importing into geth" 14; fi
rm $HOMEDIR/priv_genesis.key;
rm $PASSWD_FILE;

##############################################
# Did we get a genesis file specified?  if so decode the base64
# Otherwise we need to create one
##############################################
if [ ${#SPECIFIED_GENESIS_BLOCK} -gt 0 ]; then
	# Genesis block comes in as base64, need to decode it
	SPECIFIED_GENESIS_BLOCK=`echo ${SPECIFIED_GENESIS_BLOCK} | base64 --decode`;
	echo ${SPECIFIED_GENESIS_BLOCK} > $GENESIS_FILE_PATH;

	echo "===== Genesis block specified! =====";
else
	##############################################
	# Setup Genesis file and pre-allocated account
	##############################################
	echo "===== Starting genesis file creation =====";

	cd $HOMEDIR
	wget -N ${ARTIFACTS_URL_PREFIX}/genesis-template.json.txt || unsuccessful_exit "failed to download genesis-template.json.txt" 15;
	# Place our calculated difficulty into genesis file
	sed s/#DIFFICULTY/$DIFFICULTY/ $HOMEDIR/genesis-template.json.txt > $HOMEDIR/genesis-intermediate1.json;
	sed s/#PREFUND_ADDRESS/$ETHERBASE_ADDRESS/ $HOMEDIR/genesis-intermediate1.json > $HOMEDIR/genesis-intermediate2.json;
	sed s/#NETWORKID/$NETWORK_ID/ $HOMEDIR/genesis-intermediate2.json > $HOMEDIR/genesis.json;
fi

##################
# Extract gasLimit from genesis.json, needed for miner option targetgaslimit 
GASLIMIT=`cat "$GENESIS_FILE_PATH" | jq '.gasLimit'`;

echo "===== Completed genesis file and pre-allocated account creation =====";

cd $HOMEDIR
wget -N ${ARTIFACTS_URL_PREFIX}/scripts/start-private-blockchain.sh || unsuccessful_exit "failed to download start-private-blockchain.sh" 16;

####################
# Initialize geth for private network
####################
echo "===== Starting initialization of geth for private network =====";
if [ $NODE_TYPE -eq 1 ] && [ $MN_NODE_SEQNUM -lt $NUM_BOOT_NODES ]; then #Boot node logic
	printf %s ${NODE_KEYS[$MN_NODE_SEQNUM]} > $NODEKEY_FILE_PATH;
fi

#################
# Initialize geth
#################

# Clear out old chaindata
rm -rf $GETH_HOME/geth/chaindata
geth --datadir $GETH_HOME -verbosity 6 init $GENESIS_FILE_PATH >> $GETH_LOG_FILE_PATH 2>&1;
if [ $? -ne 0 ]; then
	unsuccessful_exit "geth initialization failed" 17;
fi
echo "===== Completed initialization of geth for private network =====";

#####################
# Setup admin website
#####################
if [ $NODE_TYPE -eq 0 ]; then # TX nodes only
	echo "===== Starting admin website setup =====";
	mkdir -p $ETHERADMIN_HOME/views/layouts;
	cd $ETHERADMIN_HOME/views/layouts;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/main.handlebars || unsuccessful_exit "failed to download main.handlebars" 18;
	cd $ETHERADMIN_HOME/views;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/etheradmin.handlebars || unsuccessful_exit "failed to download etheradmin.handlebars" 19;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/etherstartup.handlebars || unsuccessful_exit "failed to download etherstartup.handlebars" 20;
	cd $ETHERADMIN_HOME;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/package.json || unsuccessful_exit "failed to download package.json" 21;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/npm-shrinkwrap.json || unsuccessful_exit "failed to download npm-shrinkwrap.json" 22;
	npm install || unsuccessful_exit "failed while running npm install" 23;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/app.js || unsuccessful_exit "failed to download app.js" 24;
	mkdir $ETHERADMIN_HOME/public;
	cd $ETHERADMIN_HOME/public;
	wget -N ${ARTIFACTS_URL_PREFIX}/scripts/etheradmin/skeleton.css || unsuccessful_exit "failed to download skeleton.css" 25;
	echo "===== Completed admin website setup =====";
fi

#########################
# Generate boot node URLs
####################
echo "===== Starting bootnode URL generation =====";
BOOTNODE_URLS="";
for i in `seq 0 $(($NUM_BOOT_NODES - 1))`; do
	BOOTNODE_URLS="${BOOTNODE_URLS}enode://${NODE_IDS[$i]}@#${MN_NODE_PREFIX}${i}#:${GETH_IPC_PORT}";
  if [ $i -lt $(($NUM_BOOT_NODES - 1)) ]; then
  	BOOTNODE_URLS="${BOOTNODE_URLS} --bootnodes ";
  fi
done
echo "===== Completed bootnode URL generation =====";

##################
# Create conf file
##################
printf "%s\n" "HOMEDIR=$HOMEDIR" > $GETH_CFG_FILE_PATH;
printf "%s\n" "IDENTITY=$VMNAME" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "NETWORK_ID=$NETWORK_ID" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "MAX_PEERS=$MAX_PEERS" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "NODE_TYPE=$NODE_TYPE" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "BOOTNODE_URLS=$BOOTNODE_URLS" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "MN_NODE_PREFIX=$MN_NODE_PREFIX" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "NUM_BOOT_NODES=$NUM_BOOT_NODES" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "MINER_THREADS=$MINER_THREADS" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "GETH_HOME=$GETH_HOME" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "GETH_LOG_FILE_PATH=$GETH_LOG_FILE_PATH" >> $GETH_CFG_FILE_PATH;
printf "%s\n" "GASLIMIT=$GASLIMIT" >> $GETH_CFG_FILE_PATH;

if [ $NODE_TYPE -eq 0 ]; then #TX node
  printf "%s\n" "ETHERADMIN_HOME=$ETHERADMIN_HOME" >> $GETH_CFG_FILE_PATH;
  printf "%s\n" "ETHERBASE_ADDRESS=$ETHERBASE_ADDRESS" >> $GETH_CFG_FILE_PATH;
  printf "%s\n" "NUM_MN_NODES=$NUM_MN_NODES" >> $GETH_CFG_FILE_PATH;
  printf "%s\n" "TX_NODE_PREFIX=$TX_NODE_PREFIX" >> $GETH_CFG_FILE_PATH;
  printf "%s\n" "NUM_TX_NODES=$NUM_TX_NODES" >> $GETH_CFG_FILE_PATH;
  printf "%s\n" "ADMIN_SITE_PORT=$ADMIN_SITE_PORT" >> $GETH_CFG_FILE_PATH;
fi

##########################################
# Setup rc.local for service start on boot
##########################################
echo "===== Setting up rc.local for restart on VM reboot =====";
echo -e '#!/bin/bash' "\nsudo -u $AZUREUSER /bin/bash $HOMEDIR/start-private-blockchain.sh $GETH_CFG_FILE_PATH $PASSWD" | sudo tee /etc/rc.local 2>&1 1>/dev/null
if [ $? -ne 0 ]; then
	unsuccessful_exit "failed to setup rc.local for restart on VM reboot" 26;
fi
echo "===== Completed setting up rc.local for restart on VM reboot =====";

############
# Start geth
############
echo "===== Starting private blockchain network =====";
/bin/bash $HOMEDIR/start-private-blockchain.sh $GETH_CFG_FILE_PATH $PASSWD || unsuccessful_exit "failed while running start-private-blockchain.sh" 27;
echo "===== Started private blockchain network successfully =====";

echo "===== All commands in ${0} succeeded. Exiting. =====";
exit 0;
