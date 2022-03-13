#!/bin/bash

#https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux
#printf "I ${RED}love${NC} Stack Overflow\n"
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color
OK="${GREEN} ok ${NC}"
FAIL="${RED}fail${NC}"
WARN="${ORANGE}warn${NC}"

# try to read preconfigured server address from env file
#if [ -f ".env" ]; then
#    dstNode=`cat .env | xargs`
#fi

function checkError {
    if [ $? -eq 0 ]; then
        printf "[$OK] $1 \n"
    else
        printf "[$FAIL] $1 \n"
        exit 1
    fi
}

function checkLoop {
    if [ $? -eq 0 ]; then
        printf "[$OK] $1 \n"
    else
        printf "[$FAIL] $1 \n"
        return 1
    fi
}

function checkWarn {
    if [ $? -eq 0 ]; then
        printf "[$OK] $1 \n"
    else
        printf "[$WARN] $2 \n"
        return 1
    fi
}

function checkContinue {
    printf "${RED}"
    read -p "$1, continue? [y] " -n 1 -r
    printf "${NC}\n"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        return 0
    else
        return 1
    fi
}

function checkYesNo {
    printf "${RED}"
    read -p "$1, continue? [y] " -n 1 -r
    printf "${NC}\n"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        return 0
    else
        return 1
    fi
}

while true; do
    # print formated zfs list
    eval "zfs list -t volume -o name,used,avail,refer,compressratio,volsize,volblocksize,compression,encryption"
    checkError "zfs list"

    # get target volume
    while true; do
        read -e -p "Enter volume name: " -i "rpool/data/" VOLUME
        eval "zfs list -t volume -o name,used,avail,refer,compressratio,volsize,volblocksize,compression,encryption $VOLUME"
        checkLoop "find volume [$VOLUME]" && break
    done

    # check free space
    FREE=$(zfs get -p -H -o value available "${VOLUME%/*}") #check parent dataset
    NEED=$(zfs get -p -H -o value logicalused $VOLUME)
    [[ $FREE -gt $NEED ]]
    checkError "check space: free=$(($FREE/1024/1024/1024))Gb need=$(($NEED/1024/1024/1024))Gb"

    # stop VM
    while true; do
        # found VM
        VMID=$(echo $VOLUME | grep -oE "[0-9]{3}-disk-[0-9]+" | grep -oE "[0-9]{3}")
        checkWarn "VM $VMID found" "VM $VMID NOT found" || break
        # check VM status
        eval "qm list | awk ' \$1==\"$VMID\" && \$3==\"stopped\" ' | grep -q \"\" "
        checkWarn "VM $VMID is already stopped" "VM $VMID is running. It's must be stopped!" && break
        # shutdown or stop?
        read -p "Shutdown[s] or Poweroff[p]? " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]
        then
            eval "qm shutdown $VMID"
            checkLoop "VM $VMID shutdown" && break
        fi
        if [[ $REPLY =~ ^[Pp]$ ]]
        then
            eval "qm stop $VMID"
            checkLoop "VM $VMID poweroff" && break
        fi
    done

    # set properties
    while true; do
        # read old properties
        BS_OLD=$(zfs get -H -o value volblocksize $VOLUME)
        COMPRESS_OLD=$(zfs get -H -o value compression $VOLUME)
        VOLSIZE=$(zfs get -H -o value volsize $VOLUME)

        # read new properties
        read -e -p "Enter new block size: " -i "32k" BS
        read -e -p "Enter new compression size: " -i "zstd" COMPRESS
        checkContinue "$BS_OLD-$COMPRESS_OLD -> $BS-$COMPRESS" && break
    done

    # work
    eval "zfs create -s -b $BS -V $VOLSIZE -o compression=$COMPRESS $VOLUME-new"
    checkError "zfs create new volume"
    eval "time dd if=/dev/zvol/$VOLUME bs=1024k status=none conv=sparse | pv | dd of=/dev/zvol/$VOLUME-new bs=1024k status=none conv=sparse"
    #eval "time dd if=/dev/zvol/$VOLUME of=/dev/zvol/$VOLUME-new bs=1024k"
    checkError "dd copy to new volume"
    eval "zfs rename $VOLUME $VOLUME-old"
    checkError "zfs rename $VOLUME $VOLUME-old"
    eval "zfs rename $VOLUME-new $VOLUME"
    checkError "zfs rename $VOLUME-new $VOLUME"

    # Destroy old volume
    echo "Start VM VMID and check that everything works"
    checkContinue "Destroy old volume $VOLUME-old" || break
    eval "zfs destroy -r $VOLUME-old"
    checkError "zfs destroy -r $VOLUME-old"
done

# read -p "Please Enter a Message: `echo $'\n> '`" message