#!/bin/sh
# File: cdc_interface.sh
# Copyright:    IBM Corporation
# Author:   gwjensen@us.ibm.com revised and maintained by qinzhl@cn.ibm.com
# Version:  1.0.7

# Change History
# 0.8.0 VMWare 4.0 support
# 0.8.1 CentOS support (unofficial)
# 0.8.2 SLES 11 XEN support
#       Better function logging
# 0.8.3 Fix missing corner case with SLES 11 XEN -> if user does not have bridges configured, or has deleted them.
# 0.8.4 Directed ping over specified interface to make sure route does not send ping over ethernet
#       Verify USB connection established after configuration with ping to IMM
#       Additional test case for finding mac address of USB device
#       Older versions would re-write config file even when communication with the IMM already existed, this is changed
#       New return code (3)
# 0.9.0 Switch from static assigned interface address to DHCP assigned address via IMM's DHCP server as the default run method.
#       If DHCP were to fail, static ips will be assigned for each interface.
#       An Additional command line option has been added (--bringdown) that will bypass all setup instructions and bring down any current IMM interfaces
#       along with removing their config files.
#       New return code (4)
#       New return code (5)
# 0.9.1 Fixed error path message for when ping not returned successfully from the IMM when attempting to set up static addressing using pings.
#       Fall back case for VMware 4.0 when DHCP fails to assign address in multi-node setup
# 0.9.2 bringdown usb-lan no matter it is configured by user or cdc-script
# 0.9.6 fix the wrong route problem and redesign IMM_SUBNET_STARTING_ADDR to shorten the cdc run time when configuration fall to failure
#       improve the ping_imm_via_cdc_interface function so that we don't reconfigure usb-lan when it's already connected.
# 0.9.7 new option (--num) and (--nodes NodesNumber)added to querry the node numbers in multinode.
#       bcz the return code 0-199 has been occupied for other use,the return code for (--num) is like this:
#           201-299 is valid,all other return values are considered no node found;
#           the actual node number should be (201-299) - 200.
# 0.9.8 fix Rhel6 ifup issue
# 0.9.9 delete vswitch for --bringdown on vmware 4 or later
# 1.0.0 fix Rhel6 ifup/NetworkManager issue for flash (1.0.3 updates fixed this issue, so roll back the change in this version)
# 1.0.1 Aeolus fix for 169.254.0.0/16 added repeatedly on multinode system
# 1.0.2 disable NetworkManager for Rhel6 in case the ifup fail (1.0.3 updates fixed this issue, so roll back the change in this version)
# 1.0.3 Power saving restructure & Add code to save state of driver/interface and return state after flash is complete
# 1.0.4 Check cdc driver for suse and rhel, but skip for vmware
# 1.0.5 Support bring up or down each node by mac address in multi node system
# 1.0.6 Support get vswif mac address 
# 1.0.7 Disable peerdns, delete route 192.168.95.* and 192.168.96.* only
# This script will bring up the CDC network interface allowing you to communicate with the IMM

# List of possible return codes from this script ...
#   0   usbXX interface successfully brought up
#   1   Unable to load cdc_ether or usbnet driver load_driver()
#   2   Unable to find the CDC Ethernet interface in find_interface()
#   3   Failed to ping the IMM at address 169.254.X.118 where X is $IMM_SUBNET
#   4   One or more interfaces failed during bringup
#   5   Parsing Error
#   6   nodes present less than input nodes number
#   7   CDC Driver is not loaded
#   8   cannot find mac as usb interface
#   171 IMM system not detected
#   172 Unknown Operating System
#   173 Missing tools or drivers(lsusb,lsmod,modprobe) in Customer's env


# Enable/Disable bash debug ...
set -x

# Set our core variables ...
IMM_ETHER_IPADDR=169.254.95.118
IMM_SUBNET=95
#This variable is only used when doing the final
#ping to all the interfaces
IMM_SUBNETS_USED=""

#This variable is used to keep track of which interfaces are available to be tried when using ping to determine subnet.
#IMM guarantees that we shouldn't ever get to the case where we have to search all of these subnets. I put all of them
#here just as backup. Also, the IMM guarantees that the subnets will start at 95 and work upwards by one from there.
IMM_SUBNET_STARTING_ADDR="95;96;97;98;99;100;101;102;"

CDC_ETHER_IPADDR=169.254.$IMM_SUBNET.120
CDC_ETHER_NETMASK=255.255.255.0

#Used to set up the temp address for pinging
CDC_ETHER_TEMP_IPADDR=169.254.95.119
CDC_ETHER_TEMP_NETMASK=255.255.0.0
IMM_MAX_DEVICE_COUNT=4


#This variable will be used to store the MAC addresses of multiple IMM's visible to the OS
#They will be separated with a ",".
IMM_MACADDR_STRING=""
#Keeps track of how many IMMs were found
IMM_DEVICE_COUNT=0

IBM_CDC_ETHER_USB_VID_PID="04b3:4010"
SYSCONFIG_NETWORK_SCRIPTS_DIR="/etc/sysconfig/network-scripts"
IBM_GENERATED_CONFIG_FILE_TOKEN="File created by IBM"
IBM_GENERATED_CONFIG_FILE_DATA=""
RUN_STATIC_SETUP=1

IS_XEN=1 #Set to false by default
VMWARE_4=1 #Set to false by default

# Keep track of driver status before we do anything
IMM_DRIVER_STATUS=0
IMM_IFACE_STATUS=0
#VMWARE_4_TEMP_FILE="/var/log/IBM_Support/flash.ibm"

MAC_ADDR=""

generate_config_file_data(){
    #need to test esx & suse 11
    TMP_IFACE_STATUS=0
    item=0
    while [ $item -lt $IMM_MAX_DEVICE_COUNT ]
    do
        USB_SUBNET=`expr 95 + $item`
        #test ping imm
        ping -c 1 -w 2 169.254.$USB_SUBNET.118 > /dev/null
        if [ $? != 0 ]
        then
            echo "ping 169.254.$USB_SUBNET.118 failed."
        else
            echo "ping 169.254.$USB_SUBNET.118 success."
            TMP_IFACE_STATUS=1
            break
        fi
	item=`expr $item + 1`
    done
    
    IBM_GENERATED_CONFIG_FILE_DATA="
# $IBM_GENERATED_CONFIG_FILE_TOKEN
# IMM_DRIVER_STATUS=$IMM_DRIVER_STATUS
# IMM_IFACE_STATUS=$TMP_IFACE_STATUS
# IBM RNDIS/CDC ETHER
NM_CONTROLLED=no"
}

save_config_files(){
    if [ -e $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1 ]
    then
        if ( grep -q $IBM_GENERATED_CONFIG_FILE_TOKEN $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1 )
        then
            rm -f $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1
        else
            mv -f $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1 $SYSCONFIG_NETWORK_SCRIPTS_DIR/ORIGINAL.$1
        fi
    fi
}

restore_config_files(){
    if [ -e $SYSCONFIG_NETWORK_SCRIPTS_DIR/ORIGINAL.$1 ]
    then
        rm -f $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1
        mv -f $SYSCONFIG_NETWORK_SCRIPTS_DIR/ORIGINAL.$1 $SYSCONFIG_NETWORK_SCRIPTS_DIR/$1
    fi
}

#Parse the arguments passed to the script and set up global booleans
parse_command_line_args() {
    while [ $# -gt 0 ]
    do
        ARG=`echo $1 | tr '[:upper:]' '[:lower:]'`
        shift
        if [ $ARG == "--staticip" ]
        then
            #Can only explicitely run static setup on single node
            #Is only seen in the single node section of the main() code below
            RUN_STATIC_SETUP=0
        elif [ $ARG == "--restore" ]
        then
            bring_down_all_cdc
        elif [ $ARG == "--bringdown" ]
        then
            MAC_ADDR=`echo $1 | tr '[:lower:]' '[:upper:]'`
            shift			
            bring_down_cdc_by_mac
        elif [ $ARG == "--remove" ]
        then
            unload_driver
            exit 0
        elif [ $ARG == "--status" ]
        then
            if [ "$IMM_DRIVER_STATUS" == "0" ]
            then
                exit 7
            else
                exit 0
            fi
        elif [ $ARG == "--num" ]
        then
            get_nodes_num $1
			shift
        elif [ $ARG == "--bringup" ]
        then
            MAC_ADDR=`echo $1 | tr '[:lower:]' '[:upper:]'`            
            bring_up_cdc_by_mac
            shift    
        elif [ $ARG == "--nodes" ]
        then
            check_nodes_num $1
            shift
	elif [ $ARG == "--get-vswif-mac" ]
        then
            get_vswif_mac $1 $2
            shift
	fi	
   
    done
}

# Detect which Linux distribution we are running, in the case of RHEL 4 set CDC_DRIVER_NAME to "usbnet"
detect_os_variant() {

    #print interface config info here for debug
    ifconfig
    route -n

    if [ /etc/redhat-release -nt /etc/vmware-release ]
    then
        VER=`sed "s/.*release //" /etc/redhat-release | awk '{print $1}'|cut -c 1`
        MAJOR_OS=RHEL

        if [ $VER -ge 5 ]
        then
            REL=`sed "s/.*release //" /etc/redhat-release | awk '{print $1}'|cut -c 3`
            CDC_DRIVER_NAME=cdc_ether
        fi
        if [ $VER -le 4 ]
        then
            REL=`awk '{print $10}' /etc/redhat-release | cut -c 1`
            CDC_DRIVER_NAME=usbnet
        fi
        echo "RedHat Enterprise Linux Version $VER Update $REL found ..." >&1
    elif [ -f /etc/SuSE-release ]
    then
        VER=`awk 'NR==2{print $3}' /etc/SuSE-release`
        REL=`awk 'NR==3{print $3}' /etc/SuSE-release`
        CDC_DRIVER_NAME=cdc_ether
        MAJOR_OS=SLES
        echo "SuSE Linux Enterprise Server Version $VER Service Pack $REL found ..." >&1
        if [ $VER -ge 11 ]
        then
            #After the bridged connections are set up in XEN, they persist to non-XEN SLES 11.
            #Because of this, we need to check for a bridged connection to the cdc interface
            #before we attempt to set the usb0.
            IS_XEN=0
        fi
        SYSCONFIG_NETWORK_SCRIPTS_DIR="/etc/sysconfig/network"
    elif [ `vmware -v | awk '{print $1}'` == "VMware" ]
    then
        #Since vmware -v output has changed between releases need to detect the release differently
        VER3=`vmware -v | awk '{print $4}' | cut -c 1`
        VER4=`vmware -v | awk '{print $3}' | cut -c 1`
        if [ $VER3 == 3 ]
        then
            VER=3
        elif [ $VER4 == 4 ]
        then
            VER=4

            #print interface config info here for debug
            esxcfg-vswitch -l
            esxcfg-vswif -l
        fi

        # Set MAJOR_OS
        MAJOR_OS=VMWARE

        # Load correct driver
        if [ $VER == 3 ]
        then
            #Driver does not exist in VMware ESX Server 3.5 prior to U4
            CDC_DRIVER_NAME=CDCEther
        fi
        if [ $VER == 4 ]
        then
            CDC_DRIVER_NAME=cdc_ether
            VMWARE_4=0
        fi
        echo "VMware ESX Server $VER found ..." >&1
    else
        echo "Unable to detect operating system, exiting." >&1
        exit 172
    fi
}

#get nodes number in system,the accual nodes number should be (exitCode-200)
get_nodes_num() {
    macFile=$1
    exitCode=`expr $IMM_DEVICE_COUNT + 200`
    if [ ! "$macFile" == "" ]
    then
        mkdir -p ` echo $macFile | sed "s/\/[^\/]*$//" ` 1>/dev/NULL 2>&1
        echo $IMM_MACADDR_STRING > $macFile        
    fi
	
	exit $exitCode
}

#if nodes present less than $1,then exit 6
check_nodes_num() {
    nodesNum=$1
    #check validity of param
    if [ "$nodesNum" == "" ]
    then
        echo "no nodes number followed."
        exit 5
    fi

    numCnt=`expr $nodesNum : "[0-9]*$"`
    if [ $numCnt == 0 ]
    then
        echo "nodes number is invalid."
        exit 5
    fi

    #check if all nodes present
    if [ $IMM_DEVICE_COUNT -lt $nodesNum ]
    then
        echo "Not all nodes present."
        exit 6
    fi
}

# Ping default IMM (i.e. IMM_ETHER_IPADDR) through current mac
#return 0 when ping success
#return 1 when failed
ping_imm_via_mac() {
    item=0
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")

    if find_all_ip_interface
    then
        #find interface by mac
        INTERFACE=""
        find_interface_by_mac $MAC_ADDR
        if [ $INTERFACE != "" ]
        then 
            while [ $item -lt $IMM_DEVICE_COUNT ]
            do
                USB_SUBNET=`expr 95 + $item`
                
                #ping imm using this subnet
                ping -c 1 -w 2  169.254.$USB_SUBNET.118 > /dev/null
                if [ $? != 0 ]
                then
                    echo "ping 169.254.$USB_SUBNET.118 failed."
                else
                    echo "ping 169.254.$USB_SUBNET.118 success."
                    
                    #check if ping to the imm we want
                    check_imm_route
                    if [ $? != 0 ]
                    then
                        echo "check route infornmation fail."
                        break
                    fi
                    return 0
                fi

                item=`expr $item + 1`
            done
        fi
    fi
	
    IFS=$TEMP_IFS
    return 1
}

#check if ping to the right imm, using USB_SUBNET and INTERFACE_IP_LIST
check_imm_route() {
    correct_route=1
    #find the real route
    first_route=`route -n | grep 169.254.$USB_SUBNET | head -1 | awk '{print $8}' `
    if [ -z $first_route ]
    then
        first_route=`route -n | grep 169.254.0 |head -1 | awk '{print $8}' `
    fi

    #check if first_route is in the INTERFACE_IP_LIST
    TEMP_IFS5=$IFS
    IFS=$(echo -en ",")
    for route in $INTERFACE_IP_LIST
    do
    if [ "$first_route" == "$route" ]
    then
        correct_route=0
        break
    fi
    done
    IFS=$TEMP_IFS5

    return $correct_route
}
#get all the mac addr of usb dev,this func should be called after detect_os_variant and before all other func.
get_mac_addr() {
    if [ $MAJOR_OS == VMWARE ]
    then
        if [ $VER == "3" ]
        then
            #By deleting the driver and re-installing it, we insure that the functional MAC address of the
            #interface is the last loaded address and we don't have a bogus MAC like 00:00:00:00
            unload_driver
            load_driver
            vmware_check_for_imm_get_mac
            if [ $IMM_DRIVER_STATUS == 0 ]
            then
                unload_driver
            fi
        elif [ $VER == 4 ]
        then
            # No need for load_driver on VMWare 4, guaranteed to be loaded
            vmware_check_for_imm_get_mac
        fi
    else
        load_driver
        check_for_imm_get_mac
        if [ $IMM_DRIVER_STATUS == 0 ]
        then
            unload_driver
        fi
    fi
}
#find all the usb interface where the ip should be configured
#and put them in INTERFACE_IP_LIST
find_all_ip_interface() {
    INTERFACE_IP_LIST=""
    FIND_GOOD=0

    TEMP_IFS1=$IFS
    IFS=$(echo -en ",")
	
    echo "IMM_MACADDR_STRING = "$IMM_MACADDR_STRING

    for mac in  $IMM_MACADDR_STRING
    do
        #find interface
        INTERFACE=""
        find_interface_by_mac $mac
        if [ "$INTERFACE" != "" ]
        then
            echo "no interface found for $mac"
            FIND_GOOD=1
            break
        fi

        #convert interface to INTERFACE_IP
        if [ $MAJOR_OS == VMWARE ] && [ $VER != "3" ]
        then
            vmware4_find_ip_interface $INTERFACE
        elif [ $MAJOR_OS == SLES ]
        then
            find_bridged_connection $mac
            if [ $BR_INTERFACE_FOUND == 0 ]
            then
                INTERFACE_IP=$BR_INTERFACE
            else
                INTERFACE_IP=$INTERFACE
            fi
        else
            INTERFACE_IP=$INTERFACE
        fi
        if [ -z "$INTERFACE_IP" ]
        then
            echo "no INTERFACE_IP found for $INTERFACE"
            FIND_GOOD=1
            break
        fi

        #add to INTERFACE_IP_LIST
        TEMP_IFS3=$IFS
        IFS=$(echo -en ",")
        for inter in $INTERFACE_IP
        do
            #filter the repeated one
            if check_repeated_interface $inter
            then
                continue
            fi
            #add to INTERFACE_IP_LIST
            INTERFACE_IP_LIST=$INTERFACE_IP_LIST$inter","
        done
    IFS=$TEMP_IFS3
    done

    IFS=$TEMP_IFS1

    return $FIND_GOOD
}

#check if it is a repeated interface in INTERFACE_IP_LIST
check_repeated_interface() {
    repeat=1
    TEMP_IFS4=$IFS
    IFS=$(echo -en ",")
    for i in $INTERFACE_IP_LIST
    do
        if [ "$i" == "$1" ]
        then
            repeat=0
            break
        fi
    done
    IFS=$TEMP_IFS4

    return $repeat
}

#find real interface by $INTERFACE
vmware4_find_ip_interface() {
    INTERFACE_IP=""
    TEMP_IFS2=$IFS
    IFS=$(echo -en "\n\b")

    #find portgroup by interface,there could be mutiple PG for one interface
    PGs=`esxcfg-vswitch -l | grep $1 | sed -n '2,$p' | sed 's/[0-9]\{1,\}[ ]\{1,\}[0-9]\{1,\}[ ]\{1,\}.*'$1'.*[ ]\{0,\}$//' | sed 's/[ \t]*$//;s/^[ \t]*//' `

    for PG in $PGs
    do
        #find ip interface by portgroup
        interface_temp=`esxcfg-vswif -l | grep $PG | awk '{print $1}'`

        #add ip interface to INTERFACE_IP
        for inter in $interface_temp
        do
           INTERFACE_IP=$INTERFACE_IP$inter","
        done
    done

    IFS=$TEMP_IFS2

}

#this is a common interface to find interface name by mac addr
#for vmware 4 the interface is vusb which is not ip configured, the link interface is vswif where you can find ip configuration
find_interface_by_mac() {
    iMac=$1
    ret=0
    if [ $MAJOR_OS == VMWARE ] && [ $VER == "3" ]
    then
        vmware_3_find_interface $iMac
    else
        find_interface $iMac
    fi
}

find_mac_by_interface() {
    CUR_INTERFACE=$1
    CURRENT_PARSED_MAC=`cat /sys/class/net/$CUR_INTERFACE/address`
    if [ ! -z "$CURRENT_PARSED_MAC" ]
    then
        MAC_FIND=`echo $CURRENT_PARSED_MAC | sed 's/://g' | tr "[:lower:]" "[:upper:]"`
    else
        echo "ERROR:no /sys/class/net/$CUR_INTERFACE/address found!"
    fi	
}

get_vswif_mac(){
    MAC_FROM_CLI=$1
    macFile=$2
    MAC_TO_WRITE=$MAC_FROM_CLI

    #for vmware, we need to find the vswif mac, other os, we do nothing    
    if [ $MAJOR_OS == VMWARE ]
    then
        $INTERFACE=""
        $MAC_FIND=""
        find_interface_by_mac $MAC_FROM_CLI
        if [ $INTERFACE != "" ]
        then
            # First find the PortGroup Name associated with the physical CDC nic
            PORTGROUP=`esxcfg-vswitch -l | grep $INTERFACE | tail -1 | awk '{print $1}'`
            if [ ! -z "$PORTGROUP" ]
            then        				
            	#echo "The Portgroup is " $PORTGROUP
                # Next get the vswif associated with this PortGroup
                NEW_INTERFACE=`esxcfg-vswif -l | grep $PORTGROUP | head -1 | awk '{print $1}'`
                if [ ! -z "$NEW_INTERFACE" ]
                then
                    echo "The Interface is " $NEW_INTERFACE
                    find_mac_by_interface $NEW_INTERFACE
                    if [ $MAC_FIND != "" ]
                    then
                        echo "find vswif mac " $MAC_FIND 
                        MAC_TO_WRITE=$MAC_FIND
                    fi
                fi
            fi		
        fi
    fi
    		
    if [ ! "$macFile" == "" ]
    then
        mkdir -p ` echo $macFile | sed "s/\/[^\/]*$//" ` 1>/dev/NULL 2>&1
        echo $MAC_TO_WRITE > $macFile        
    fi
	
    exit 0		
}

# Chech the current status of the driver
get_driver_status() {
    if [ $MAJOR_OS == VMWARE ] && [ $VER == "4" ]
    then
        CDC_DRIVER=`esxcfg-module -q  | grep cdc_ether`
        if [ ! -z "CDC_DRIVER" ]
        then
            IMM_DRIVER_STATUS=1
        fi
        return
    fi

    CDC_DRIVER_LOADED=`lsmod | awk '{ print $1 }' | grep $CDC_DRIVER_NAME`
    
    if [ "$CDC_DRIVER_LOADED" == "$CDC_DRIVER_NAME" ]
    then
        IMM_DRIVER_STATUS=1
    fi
}

# Load the cdc_ether or usbnet driver, depending on the OS ...
load_driver() {

    #vmware 4 or later, the driver guaranteed to be loaded, so just check if it is enable
    if [ $MAJOR_OS == VMWARE ] && [ $VER -ge 4 ]
    then
        esxcfg-module -e cdc_ether.o
        if [ "$?" != "0" ]
        then
            echo "fail to enable cdc module for vmware 4. Please check if load cdc module when boot."
            exit 173
        fi
						
    return
    fi

    CMD_STATUS=0
    CDC_DRIVER_LOADED=`lsmod | awk '{ print $1 }' | grep $CDC_DRIVER_NAME`
    #check if lsmod succeed on user's env
    if [ "$?" != "0" ]
    then
        CMD_STATUS=1
    fi
    
    if [ "$CDC_DRIVER_LOADED" != "$CDC_DRIVER_NAME" ]
    then
        if !( modprobe $CDC_DRIVER_NAME)
        then
            echo "Could not load driver, $CDC_DRIVER_NAME ..." >&2
            if [ $CMD_STATUS == 1 ]
            then
                #maybe user's env has already loaded the CDC_DRIVER, and we are not able to detect the status bcz of lsmod fail,
                #exit 173 so that invoker aware of this
                exit 173
            else
            	exit 1
            fi
        fi
    fi
}

#saw a problem in VMWare 3.5 where the driver was already loaded and we had problems finding the MAC address
unload_driver(){
    #vmware 4 , the driver guaranteed to be loaded, so just disable it
    if [ $MAJOR_OS == VMWARE ] && [ $VER == "4" ]
    then
        esxcfg-module -d cdc_ether.o
        return
    fi
		
    CDC_DRIVER_LOADED=`lsmod | awk '{ print $1 }' | grep $CDC_DRIVER_NAME`
    if [ "$CDC_DRIVER_LOADED" == "$CDC_DRIVER_NAME" ]
    then
        if !( modprobe -r $CDC_DRIVER_NAME)
        then
            echo "Could not delete driver, $CDC_DRIVER_NAME ..." >&2
        fi
    fi
}

# Determine if we are on an IMM system and for Linux get the MAC here
check_for_imm_get_mac() {
    #NOTE: This function will not be able to find the MAC address for VMWare 3. The address will be discovered in vmware_3_find_interface()

    # RHEL 4 has a bug with "lsusb -v -d VID:PID", but -s works with the -v, so we pull the
    # BUS:DEVICE from our device line and use "lsusb -v -s BID:DID" which does work on RHEL 4
    echo "Finding MAC address...."
    #add these two lines in case it is called repeated
    IMM_MACADDR_STRING=""
    IMM_DEVICE_COUNT=0
    # Get the output from lsusb
    LSUSB_OUT=`lsusb`
    #check if lsusb succeed on user's env
    if [ "$?" != "0" ]
    then
        echo "lsusb failed,not able to go on running cdc_interface.sh."
        exit 173
    fi

    # Set bash internal field separator to newline
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b")

    # Parse through output of lsusb, looking for our known USB VID:PID
    LSUSB_BUS=null

    for i in $LSUSB_OUT
    do
        # Parse out USB VendorID:ProductID
        LSUSB_OUT_VID_PID=`echo $i | awk '{print $6}'`

        # Check against our known USB VendorID:ProductID
        if [ "$LSUSB_OUT_VID_PID" == "$IBM_CDC_ETHER_USB_VID_PID" ]
        then
            # Parse out our BusID:DeviceID
            # We remove the zero because RHEL 5.4 doesn't like it.
            LSUSB_BUS=`echo $i | awk '{print $2}' | sed 's/^0*//g'`
            LSUSB_DEVICE=`echo $i | awk '{print $4}' | sed 's/://g' | sed 's/^0*//g'`

            LSUSB_iMAC=`lsusb -v -s $LSUSB_BUS:$LSUSB_DEVICE | grep -i mac | awk '{print $3}'`

            if [ -z "$LSUSB_iMAC" ]
            then
                #String is empty we have a problem here.
                echo "The MAC address in lsusb does not present itself."
            else
                IMM_MACADDR_STRING=$IMM_MACADDR_STRING$LSUSB_iMAC","
                IMM_DEVICE_COUNT=`expr $IMM_DEVICE_COUNT + 1`
                echo "Found " $IMM_DEVICE_COUNT " Devices "
            fi

        fi
    done

    # Set bash internal field separator back to original value
    IFS=$ORIG_IFS

    if [ $IMM_DEVICE_COUNT == 0  ]
    then
        echo "IMM system not detected"
        echo "Show all USB devices via lsusb:"
        lsusb
        exit 171
    fi
}


# Parse the kernel ring buffer for cdc ethernet driver instances
# and compare with our known MAC to find the interface name
find_interface() {

    LSUSB_iMAC=$1
    echo "Looking for the interface name..."
    INTERFACE_FOUND=0
    INTERFACE=""

    # Get the USB interface list all usb network instances.  We look at /sys/class/net/* for usbX device
    # names, this would ensure the device is in use and registered.
    #SYS_CDC_ETHER_LIST=`ls /sys/class/net | grep "usb"`
    SYS_CDC_ETHER_LIST=`ls /sys/class/net | grep -E '(usb|eth|enp)'`

    # Set bash internal field separator to newline
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b ")

    echo "Looking for device with MAC of " $LSUSB_iMAC
    for i in $SYS_CDC_ETHER_LIST
    do
        INTERFACE_TEST=`echo $i`

        # Get current MAC
        CURRENT_PARSED_MAC=`cat /sys/class/net/$INTERFACE_TEST/address`
        COLON_STRIPPED_CURRENT_PARSED_MAC=`echo $CURRENT_PARSED_MAC | sed 's/://g' | tr "[:lower:]" "[:upper:]"`

        if [ "$COLON_STRIPPED_CURRENT_PARSED_MAC" == "$LSUSB_iMAC" ]
        then
            INTERFACE=$INTERFACE_TEST

            # Set INTERFACE_FOUND
            INTERFACE_FOUND=1

            # Set INTERFACE_MAC
            INTERFACE_MAC=$CURRENT_PARSED_MAC

            break
        fi
    done

    IFS=$(echo -en "\n\b")
    if [ "$INTERFACE_FOUND" == 0 ]
    then
        # Try getting the mac address out of 'dmesg' instead
        # Get the MAC for usb device 04b3:4010 and all MACs from all cdc_ether driver instances
        DMESG_CDC_ETHER_MACS=`dmesg | grep "CDC Ethernet Device"`

        # Parse through cdc_ether driver instance MACs, match up with MAC from lsusb of IBM's CDC device
        for i in $DMESG_CDC_ETHER_MACS
        do
            # Only parse lines that are for driver registration ...
            if [ `echo $i | awk '{print $2}'` == "register" ]
            then
                # Parse out the MAC from this driver registration instance
                CURRENT_PARSED_MAC=`echo $i | awk 'NR==1{print $9}'`
                COLON_STRIPPED_CURRENT_PARSED_MAC=`echo $CURRENT_PARSED_MAC | sed 's/://g' | tr "[:lower:]" "[:upper:]"`
                # Test parsed MAC against our known MAC
                if [ "$COLON_STRIPPED_CURRENT_PARSED_MAC" == "$LSUSB_iMAC" ]
                then
                    # Found our device, set preliminary insterface name
                    INTERFACE_PRELIM=`echo $i | awk 'NR==1{print $1}'`

                    # Parse out the trailing colon from the interface name
                    INTERFACE=`echo -n "$INTERFACE_PRELIM" | sed 's/://g' | sed 's/ //g'`

                    # Set INTERFACE_FOUND
                    INTERFACE_FOUND=1
                    INTERFACE_MAC=$CURRENT_PARSED_MAC

                    # Don't break here, instead continue the for loop so that
                    # we make sure we get the most recent instance of the driver loading
                    # that also matches our known MAC, in case the interface name was different
                    # for a previous registration of the driver for our MAC
               fi
           fi
       done
    fi

    # Set bash internal field separator back to original value
    IFS=$ORIG_IFS


    # VMware 4 hack, until we figure out what replace lsusb
    #if [ $MAJOR_OS == "VMWARE" ] && [ $VER == "4" ]
    #then
    #   INTERFACE_FOUND=1
    #   INTERFACE=usb0
    #fi

    # If interface was not found, exit 2
    if [ "$INTERFACE_FOUND" == "0" ]
    then
        echo "Could not locate the CDC Interface"
        exit 2
    fi
}

#Compare the colon stripped mac address of the usb interface to those of the brX interfaces to find the correct bridge
#This is needed only for SLES 11 with XEN and potential newer versions of SLES 11
find_bridged_connection() {
    LSUSB_iMAC=$1
    BR_INTERFACE_FOUND=1
    echo "Looking for interface bridge..."
    # Get the br interface list all br network instances.  We look at /sys/class/net/* for brX device
    # names, this would ensure the device is in use and registered.
    SYS_BR_LIST=`ls /sys/class/net | grep "br"`

    # Set bash internal field separator to newline
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b")

    for i in $SYS_BR_LIST
    do
        BR_INTERFACE_TEST=`echo $i`

        # Get current MAC
        BR_CURRENT_PARSED_MAC=`cat /sys/class/net/$BR_INTERFACE_TEST/address`
        BR_COLON_STRIPPED_CURRENT_PARSED_MAC=`echo $BR_CURRENT_PARSED_MAC | sed 's/://g' | tr "[:lower:]" "[:upper:]"`

        if [ "$BR_COLON_STRIPPED_CURRENT_PARSED_MAC" == "$LSUSB_iMAC" ]
        then
            BR_INTERFACE=$BR_INTERFACE_TEST

            # Set INTERFACE_FOUND
            BR_INTERFACE_FOUND=0

            # Set INTERFACE_MAC
            BR_INTERFACE_MAC=$BR_CURRENT_PARSED_MAC

            break
        fi
    done

    if [ "$BR_INTERFACE_FOUND" == 1 ]
    then
        #We did not find a bridged connection. This means that the user is either
        #running standard SLES 11 w/o XEN, or the user has not configured their
        #hypervisor to set up the briged network connections. Now we need to attempt
        #to set up the usb0 instead of brX.
        echo "Could not locate the Bridge for the CDC interface."
        echo "Attempting to bring up alternate interface..."
        IS_XEN=1

    fi

    # Set bash internal field separator back to original value
    IFS=$ORIG_IFS

}
#VMWare3 function to find the interface
vmware_3_find_interface() {
    TEMP_MAC=$1
    INTERFACE=""
    echo "TEMP_MAC = " $TEMP_MAC
    INTERFACE=`dmesg | sed 's/://g' | tr "[:upper:]" "[:lower:]" | grep -i $TEMP_MAC | tail -1 | awk '{print $2}'`
    echo "The interface is " $INTERFACE
}

# VMware function to find the mac address
vmware_check_for_imm_get_mac() {
    echo "Getting the mac address of the network device."
    #VMWare4 has a bug where lsusb -v -s doesn't work correctly, and since RHEL4
    #has a bug with lsusb -v -d we needed a separate function
    IMM_MACADDR_STRING=""
    IMM_DEVICE_COUNT=0
    # Set bash internal field separator to newline and space
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b ")

    if [ $VMWARE_4 == 1 ] #not VMWare4
    then
        #VMWare 3
        DMESG_OUT=`dmesg | grep -i rndis | grep -i cdc | grep -i ibm | awk '{print $2}' | head -1`

        TEMP_MAC=`dmesg | grep $DMESG_OUT | egrep "[[:alnum:]][[:alnum:]]:[[:alnum:]][[:alnum:]]" | tail -1 | awk '{print $3}' | tr "[:upper:]" "[:lower:]" | sed 's/://g' | sed 's/ //g'`
        IMM_MACADDR_STRING=$IMM_MACADDR_STRING$TEMP_MAC","
        IMM_DEVICE_COUNT=`expr $IMM_DEVICE_COUNT + 1`

        echo "MAC_ADDR_STRING = " $IMM_MACADDR_STRING

    else
        #VMWARE4

        echo "Finding MAC address...."

        # Get the output from lsusb
        LSUSB_OUT=`lsusb -v -d $IBM_CDC_ETHER_USB_VID_PID | grep -i mac | awk '{print $3}'`

        # Parse through output of lsusb, looking for our known USB VID:PID
        LSUSB_BUS=null

        for i in $LSUSB_OUT
        do
             IMM_MACADDR_STRING=$IMM_MACADDR_STRING$i","
             IMM_DEVICE_COUNT=`expr $IMM_DEVICE_COUNT + 1`
        done

        # In Vmware4, dmesg can not offer mac address, so we could do nothing if lsusb fail here
    fi

    # Set bash internal field separator back to original value
    IFS=$ORIG_IFS

    # If interface was not found, exit 2
    if [ $IMM_DEVICE_COUNT -lt 1 ]
    then
        echo "IMM System not detected."
        echo "Show all USB devices via lsusb:"
        lsusb
        exit 171
    fi
}

check_for_previous_config_file(){
    echo "Checking for old config files."
    #Set flag for persistent device names in use
    PERS_NAME=0

    # Set bash internal field separator to newline
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b")

    save_config_files ifcfg-$INTERFACE
    save_config_files ifcfg-$BR_INTERFACE
    save_config_files ifcfg-usb-id-$INTERFACE_MAC
    if [ -e $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC ]
    then
        PERS_NAME=1
    fi
    IFS=$ORIG_IFS
}

# Write out the DHCP config file for the interface ...
write_config_file_dhcp() {
    echo "Writing config file for DHCP..."

    generate_config_file_data

    # Write out new ifcfg-$INTERFACE or ifcfg-usb-id-$INTERFACE_MAC
    if [ $MAJOR_OS == RHEL ] || [ $MAJOR_OS == VMWARE ]
    then
        if [ $PERS_NAME == 0 ]
        then
            echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nONBOOT=yes\nBOOTPROTO=dhcp\nPEERDNS=no\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE
        else
            echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nONBOOT=yes\nBOOTPROTO=dhcp\nPEERDNS=no\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
        fi
    elif [ $MAJOR_OS == SLES ]
    then
        if [ $IS_XEN == 0 ]
        then
            if [ $PERS_NAME == 0 ]
            then
                #echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='static'\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nBROADCAST=''\nETHTOOL_OPTIONS=''\nIPADDR='$CDC_ETHER_IPADDR'\nMTU=''\nNETMASK='$CDC_ETHER_NETMASK\nNETWORK=''\nREMOTE_IPADDR=''\nSTARTMODE='auto'\nUSERCONTROL='no'\nNAME=''" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$BR_INTERFACE
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='dhcp'\nPEERDNS=no\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nSTARTMODE='auto'\nUSERCONTROL='no'" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$BR_INTERFACE
            else
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='dhcp'\nPEERDNS=no\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nSTARTMODE='auto'\nUSERCONTROL='no'" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
            fi
        else
            if [ $PERS_NAME == 0 ]
            then
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nSTARTMODE=auto\nBOOTPROTO=dhcp\nPEERDNS=no\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE
            else
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nSTARTMODE=auto\nBOOTPROTO=dhcp\nPEERDNS=no\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
            fi
        fi
    fi

}
# Write out the static config file for the interface...
write_config_file_static(){
    echo "Writing a static config file"

    generate_config_file_data

    # Write out new ifcfg-$INTERFACE or ifcfg-usb-id-$INTERFACE_MAC
    if [ $MAJOR_OS == RHEL ] || [ $MAJOR_OS == VMWARE ]
    then
        if [ $PERS_NAME == 0 ]
        then
            echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nONBOOT=yes\nBOOTPROTO=static\nIPADDR=$CDC_ETHER_IPADDR\nNETMASK=$CDC_ETHER_NETMASK\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE
        else
            echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nONBOOT=yes\nBOOTPROTO=static\nIPADDR=$CDC_ETHER_IPADDR\nNETMASK=$CDC_ETHER_NETMASK\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
        fi
    elif [ $MAJOR_OS == SLES ]
    then
        if [ $IS_XEN == 0 ]
        then
            if [ $PERS_NAME == 0 ]
            then
                #echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='static'\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nBROADCAST=''\nETHTOOL_OPTIONS=''\nIPADDR='$CDC_ETHER_IPADDR'\nMTU=''\nNETMASK='$CDC_ETHER_NETMASK\nNETWORK=''\nREMOTE_IPADDR=''\nSTARTMODE='auto'\nUSERCONTROL='no'\nNAME=''" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$BR_INTERFACE
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='static'\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nIPADDR='$CDC_ETHER_IPADDR'\nNETMASK='$CDC_ETHER_NETMASK'\nSTARTMODE='auto'\nUSERCONTROL='no'" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$BR_INTERFACE
            else
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nBOOTPROTO='static'\nBRIDGE='yes'\nBRIDGE_FORWARDDELAY='0'\nBRIDGE_PORTS='$INTERFACE'\nBRIDGE_STP='off'\nIPADDR='$CDC_ETHER_IPADDR'\nNETMASK='$CDC_ETHER_NETMASK'\nSTARTMODE='auto'\nUSERCONTROL='no'" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
            fi
        else
            if [ $PERS_NAME == 0 ]
            then
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nSTARTMODE=auto\nBOOTPROTO=static\nIPADDR=$CDC_ETHER_IPADDR\nNETMASK=$CDC_ETHER_NETMASK\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE
            else
                echo -e "$IBM_GENERATED_CONFIG_FILE_DATA\nDEVICE=$INTERFACE\nSTARTMODE=auto\nBOOTPROTO=static\nIPADDR=$CDC_ETHER_IPADDR\nNETMASK=$CDC_ETHER_NETMASK\nHWADDR=$INTERFACE_MAC\nTYPE=Ethernet" > $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-usb-id-$INTERFACE_MAC
            fi
        fi
    fi
}

#Add an alias for the network driver for certain OSs
set_driver_alias_for_network_restart(){

    # RHEL 4 doesn't load the driver, so we need to add an alias so that when
    # the network restarts during a flash, our interface comes back
    if [ $MAJOR_OS == RHEL ] && [ $VER == 4 ]
    then
        # Check to see if our interface is already in modprobe.conf
        DRIVER_ALIAS=`grep $INTERFACE /etc/modprobe.conf | awk '{print $3}'`
        # If no alias, just add one
        if [ -z "$DRIVER_ALIAS"  ]
        then
            # Add the correct alias to the end of the file,
            # so that we are sure USB aliases have already been set
            echo "alias" $INTERFACE $CDC_DRIVER_NAME >> /etc/modprobe.conf
        elif [ "$DRIVER_ALIAS" != "$CDC_DRIVER_NAME" ]
        then
            # Remove any alias of our interface that does not
            # correspond to the correct driver
            mv -f /etc/modprobe.conf /etc/ORIGINAL.modprobe.conf 
            grep -v "$DRIVER_ALIAS" /etc/ORIGINAL.modprobe.conf > /etc/modprobe.conf

            # Add the correct alias to the end of the file,
            # so that we are sure USB aliases have already been set
            echo "alias" $INTERFACE $CDC_DRIVER_NAME >> /etc/modprobe.conf
        fi
    fi

    # VMWare 3.5doesn't load the driver, so we need to add an alias so that when
    # the network restarts during a flash, our interface comes back
    if [ $MAJOR_OS == VMWARE ] && [ $VER == 3 ]
    then
        echo "the interface is " $INTERFACE
        # Check to see if our interface is already in modules.conf
        DRIVER_ALIAS=`grep $INTERFACE /etc/modules.conf | awk '{print $3}'`
        # If no alias, just add one
        if [ -z "$DRIVER_ALIAS"  ]
        then
            # Add the correct alias to the end of the file,
            # so that we are sure USB aliases have already been set
            echo "alias" $INTERFACE $CDC_DRIVER_NAME >> /etc/modules.conf
        elif [ "$DRIVER_ALIAS" != "$CDC_DRIVER_NAME" ]
        then
            # Remove any alias of our interface that does not
            # correspond to the correct driver
            mv -f /etc/modules.conf /etc/ORIGINAL.modules.conf 
            grep -v "$DRIVER_ALIAS" /etc/ORIGINAL.modules.conf > /etc/modules.conf

            # Add the correct alias to the end of the file,
            # so that we are sure USB aliases have already been set
            echo "alias" $INTERFACE $CDC_DRIVER_NAME >> /etc/modules.conf
        fi
    fi

}

#Determine the correct interface to use to display information
get_correct_interface() {
    echo "Determining interface name"
    if [ $IS_XEN == 0 ]
    then
        CORRECT_INTERFACE=$BR_INTERFACE
    else
        CORRECT_INTERFACE=$INTERFACE
    fi

}

# Bring up the interface and try to communicate with the IMM ...
bring_up_cdc() {
    echo "Attempting to bring up the interface"
    get_correct_interface

    #Make sure that in the XEN environment the usb0 interface is down
    #Technically, the bridge on the XEN environment needs usb0 to be up, but not configured to run correctly.
    #This is the reason usb0 is taken down before the bridge connection, since the bridge connection will bring it
    #back up correctly.
    if [ $IS_XEN == 0 ]
    then
        #Note:The configuration file for this interface has already been deleted in write_config_file()
        ifdown $INTERFACE
    fi
    echo "bringing down the interface in case it is already configured."
    # First bring down the interface, in case it is already up but not configured properly
    ifdown $CORRECT_INTERFACE

    # for rhel6, Pausing for 5 seconds to let system quiesce
    if [ $MAJOR_OS == RHEL ] && [ $VER == 6 ]
    then
        echo "Pausing for 5 seconds to let system quiesce..."
        sleep 5
    fi
	
    # Try to bring up the interface ...
    ifup $CORRECT_INTERFACE
    if [ $? != 0 ]
    then
        echo "We could not bring up interface $CORRECT_INTERFACE" >&2
        return 1
    fi
    echo "Brought up the interface successfully"
    return 0
}

#bring down the cdc interfaces match the MAC_ADDR
#This function is only envoked from the argument --bringdown to this script
# For the interface, find it and bring it down
# then unload the driver
# then  restore its original driver state
# this is needed because some OSes will bring up all interfaces when the driver is loaded
do_bring_down_cdc_by_mac(){
    IMM_DRIVER_HANDLED=0
	
    if [ $MAJOR_OS == VMWARE ]
    then
        # Set bash internal field separator to comma
        TEMP_IFS=$IFS
        IFS=$(echo -en ",")

        if [ $VER == "3" ]
        then
            #####
            ##
            ## VMWARE 3 is not supported by multi-node systems
            ##
            #####

            #####
            #We keep the for loop here because vmware 3 uses dmesg to find the interface, and because of this
            #it is possible to get multiple instances of the same interface back.
            #####

            vmware_3_find_interface $MAC_ADDR
            echo  $INTERFACE "found,bringdown it and remove config file."
            ifdown $INTERFACE

            #careless of original interface status,just restore original config file
            #restore original driver status
            IMM_DRIVER_STATUS=0
            DRV=`grep "IMM_DRIVER_STATUS" $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE | awk -F= '{ print $2 }'`
            if [ "$DRV" == "0" ]
            then
                IMM_DRIVER_STATUS=0
            elif [ "$DRV" == "1" ]
            then
                IMM_DRIVER_STATUS=1
            else
                IMM_DRIVER_HANDLED=0
                IMM_DRIVER_STATUS=1
            fi
            
            restore_config_files ifcfg-$INTERFACE
			
            if [ "$IMM_DRIVER_STATUS" == "1" ]
            then
                if [ "$IMM_DRIVER_HANDLED" == "0" ]
                then
                    load_driver
                    IMM_DRIVER_HANDLED=1
                    #give the driver a chance to load
                    sleep 10
                fi
            fi
        elif [ $VER == 4 ]
        then
            # No need for write_config_file on VMWare 4, esxcfg-vswitch and esxcfg-vswif write their own configs
            # No need for disable_zeroconf on VMWare 4, esxcfg-vswif takes care of the unneeded link-local routes

            #If no temp file, then we did nothing so leave as is
			
			#modify by cindy, we bring down anyway when called to
            #if [ -f $VMWARE_4_TEMP_FILE ]
            #then
                if [ $IMM_DEVICE_COUNT -gt 0 ]
                then
                    find_interface $MAC_ADDR
                    vmware4_delete_vswif_by_usb $INTERFACE
                    			
                    # delete vswitch
                    present=`esxcfg-vswitch -l|grep IBM_CDC_vSwitch0|awk '{print $1}'`
                    if [ ! -z $present ]
                    then
                        esxcfg-vswitch -d IBM_CDC_vSwitch0
                    fi
                fi
				
				#restore driver status when it is recorded,else, do nothing
				#if [ -f $VMWARE_4_TEMP_FILE ]
				#then
                #    DRV=`grep "IMM_DRIVER_STATUS" $VMWARE_4_TEMP_FILE | awk -F= '{ print $2 }'`
                #    if [ "$DRV" == "0" ]
                #    then
                #        unload_driver
                #    fi
				#fi

            #    rm -f $VMWARE_4_TEMP_FILE
            #fi #Temp File
        fi # VMWare 4

        IFS=$TEMP_IFS
    else  #Linux
        # Set bash internal field separator to comma
        TEMP_IFS=$IFS
        IFS=$(echo -en ",")

        if [ $IMM_DEVICE_COUNT -gt 0 ]
        then
            find_interface $MAC_ADDR
            if [ $IS_XEN == 0 ]
            then
                #We attempt to find the bridged interface after the normal usb interface so that the functions following
                #this one can use the IS_XEN value that is set in find_bridged_connection to determine whether to use
                #$INTERFACE or $BR_INTERFACE when writing the file.
                find_bridged_connection $MAC_ADDR
            fi

            if [ $IS_XEN == 0 ]
            then
                INTERFACE=$BR_INTERFACE
            fi

            echo  $INTERFACE "found,bringdown it and remove config file."
            ifdown $INTERFACE

            DRV=`grep "IMM_DRIVER_STATUS" $SYSCONFIG_NETWORK_SCRIPTS_DIR/ifcfg-$INTERFACE | awk -F= '{ print $2 }'`
            if [ "$DRV" == "0" ]
            then
                IMM_DRIVER_STATUS=0
            elif [ "$DRV" == "1" ]
            then
                IMM_DRIVER_STATUS=1
            else
                IMM_DRIVER_HANDLED=0
                IMM_DRIVER_STATUS=1
            fi               

            restore_config_files ifcfg-$INTERFACE

            if [ "$IMM_DRIVER_STATUS" == "1" ]
            then
                if [ "$IMM_DRIVER_HANDLED" == "0" ]
                then
                    load_driver
                    IMM_DRIVER_HANDLED=1
                    #give the driver a chance to load
                    sleep 10
                fi
            fi

        fi
        IFS=$TEMP_IFS
    fi

    return 0
}

#bring down the cdc interfaces match the MAC_ADDR
#This function is only envoked from the argument --bringdown to this script
# For the interface, find it and bring it down
# then unload the driver
# then  restore its original driver state
# this is needed because some OSes will bring up all interfaces when the driver is loaded
bring_down_cdc_by_mac(){
    IMM_DRIVER_HANDLED=0
	
    #check if MAC specifyed is one of our usb interface
    check_if_usbmac_exist $MAC_ADDR
    if [ $? != 0 ]
    then
        echo "cannot find mac as usb interface." >&1
    	exit 8
    fi
	
	do_bring_down_cdc_by_mac
	ret=$?
	if [ $ret != 0 ]
    then
        echo "fail to bring down cdc "$MAC_ADDR >&1
    	exit $ret
    fi

    exit 0
}

#bring down all cdc interface
bring_down_all_cdc()
{
	ret=0
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")
	
    echo "begin to bring down all cdc..."
	
	
    for MAC in  $IMM_MACADDR_STRING
    do
        MAC_ADDR=$MAC
        do_bring_down_cdc_by_mac
        ret=$?
        if [ $ret != 0 ]
		then
            echo "fail to bring down "$MAC
        fi
    done

    IFS=$TEMP_IFS
    exit $ret
}


#Look and see if there is an interface that is disabled for the cdc device
vmware4_delete_previous_interfaces() {
    echo "Looking for current interface(s)..."
    #check to see if there is already vswif NIC setup, but disabled
    DISABLED_INTERFACE=`esxcfg-vswif -l | grep IBM_CDC_PG | awk '{print $1}'`

    if [ -z "$DISABLED_INTERFACE" ]
    then
        echo "Interface not disabled."
    else
        echo "Found Previous Interface(s) " $DISABLED_INTERFACE
        # Set bash internal field separator to newline
        ORIG_IFS=$IFS
        IFS=$(echo -en "\n\b ")
        for i in $DISABLED_INTERFACE
        do
            esxcfg-vswif -d $i
            if [ $? == 0 ]
            then
                echo "Deleted interface " $i
            fi
        done
        IFS=$ORIG_IFS
        return 0
    fi

    return 1
}

#delete vswif by the usb interface name
vmware4_delete_vswif_by_usb() {
    USB_INTERFACE=$1
    ret=0
    # Set bash internal field separator to newline
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b")

    CDC_PGs=`esxcfg-vswitch -l|grep $USB_INTERFACE|sed -n '2,$p'|sed 's/[0-9]\{1,\}[ ]\{1,\}[0-9]\{1,\}[ ]\{1,\}.*'$1'.*[ ]\{0,\}$//' |sed 's/[ \t]*$//;s/^[ \t]*//'  `

    for CDC_PG in $CDC_PGs
    do
        #check to see if there is already vswif NIC setup, but disabled
        DISABLED_INTERFACE=`esxcfg-vswif -l | grep $CDC_PG | awk '{print $1}'`

        if [ -z "$DISABLED_INTERFACE" ]
        then
            echo "Interface not found."
        else
            echo "Found Interface(s) " $DISABLED_INTERFACE "using usb"

            for i in $DISABLED_INTERFACE
            do
                iusb=`esxcfg-vswif -l |grep $i|grep 169.254|awk '{print $1}'`
                if [ "$iusb" != "" ]
                then
                    esxcfg-vswif -d $i
                    if [ $? == 0 ]
                    then
                        echo "Deleted interface " $i
                    fi
                fi
            done
            ret=0
        fi
    done

    IFS=$ORIG_IFS
    ret=1
    return $ret
}

# For VMWare 4.0, bring up the interface
vmware_4_bring_up_cdc() {
    runDHCP=$1
    present=""

    # Add vswitch "IBM_CDC_vSwitch0"
    present=`esxcfg-vswitch -l|grep IBM_CDC_vSwitch0|awk '{print $1}'`
    if [ -z $present ]
    then
        esxcfg-vswitch -a IBM_CDC_vSwitch0
    fi

    # Add portgroup "IBM_CDC_PG" to vswitch "IBM_CDC_vSwitch0"
    present=`esxcfg-vswitch -l|grep IBM_CDC_PG|awk '{print $1}'`
    if [ -z $present ]
    then
        esxcfg-vswitch -A IBM_CDC_PG IBM_CDC_vSwitch0
    fi

    # Delete physical nic (pnic) $INTERFACE from any vswitch
    usb_vswitch=`esxcfg-vswitch -l|grep $INTERFACE|head -1|awk '{print $1}'`
    if [ ! -z $usb_vswitch ]
    then
        vswitch_len=`expr length "$usb_vswitch"`
        if [ "$vswitch_len" -gt "16" ]
        then
            vswitch_len=`expr $vswitch_len - 2`
            usb_vswitch=`echo $usb_vswitch|cut -c1-$vswitch_len`
        fi
        esxcfg-vswitch -U $INTERFACE $usb_vswitch

    fi

    # Add physical nic (pnic) $INTERFACE to vswitch "IBM_CDC_vSwitch0"
    esxcfg-vswitch -L $INTERFACE IBM_CDC_vSwitch0

    # Add vswif, check for existing interfaces and grab the next available one
    COUNT=0
    for (( ; ; ))
    do
        VSWIF_INT=vswif$COUNT

        if [ `esxcfg-vswif -c $VSWIF_INT` == 0 ]
        then
            #echo "#IMM_IFACE_STATUS=$MAC_ADDR=$IMM_IFACE_STATUS" >> $VMWARE_4_TEMP_FILE

            if [ -z "$runDHCP" ]
            then
                echo "Setting up connection with Static Address"
                #delete the repeated vswif
                present=`esxcfg-vswif -l|grep 169.254.95.119|awk '{print $1}'`
                if [ "$present" != "" ]
                then
                    esxcfg-vswif -d $present
                fi
                # we only need one vswif with 169.254.95.119/16, then both 169.254.95.118 and 169.254.96.118 can be pinged.
                esxcfg-vswif -a -i $CDC_ETHER_TEMP_IPADDR -n $CDC_ETHER_TEMP_NETMASK -p IBM_CDC_PG $VSWIF_INT
                if [ $? == 1 ]
                then
                    esxcfg-vswif -i $CDC_ETHER_IPADDR -n $CDC_ETHER_TEMP_NETMASK $VSWIF_INT
                fi

            else
                echo "Setting up connection with DHCP address"
                esxcfg-vswif -a -i DHCP -p IBM_CDC_PG $VSWIF_INT
                if [ $? == 1 ]
                then
                    return 1
                fi
            fi
            INTERFACE=$VSWIF_INT
            break
        fi

        COUNT=$(($COUNT+1))
    done
    return 0
}
#take all of the config files and rewrite them for DHCP
vmware_4_modify_interface(){

    vmware_4_imm_already_up_get_vswif_interface

    echo "Modifying the previous interface"
    esxcfg-vswif -i DHCP $INTERFACE

}

# If VMWare 4 and if IMM is already able to be pinged, we still need to get our vswif interface name to pass back
vmware_4_imm_already_up_get_vswif_interface() {

    # First find the PortGroup Name associated with the physical CDC nic
    PORTGROUP=`esxcfg-vswitch -l | grep vusb0 | tail -1 | awk '{print $1}'`

    if [ -z "$PORTGROUP" ]
    then
        return 1
    fi
    #echo "The Portgroup is " $PORTGROUP
    # Next get the vswif associated with this PortGroup
    INTERFACE=`esxcfg-vswif -l | grep $PORTGROUP | head -1 | awk '{print $1}'`
    #echo "The Interface is " $INTERFACE

    return 0
}

# Remove all link local routes that might exist, except for our interface
delete_link_local_routes() {
    # This link-local route exists on some distributions on interfaces besides the IMM and will prevent us from
    # talking with the IMM so we attempt to remove it here. If the route does not exist this will fail but we don't care ...
    ORIG_IFS=$IFS
    IFS=$(echo -en "\n\b")
    if [ $MAJOR_OS == VMWARE ] && [ $VER == "3" ]
    then
        routes=`route -n | grep -E "^169.254.95|^169.254.96|^169.254.0"`
        for i in $routes
        do
            net=`echo $i | awk '{print $1}'`
            netmask=`echo $i | awk '{print $3}'`
            route del -net $net netmask $netmask
        done
    else
        routes=`ip route | grep -E "^169.254.95|^169.254.96|^169.254.0"`
        for i in $routes
        do
            ip route del `echo $i | awk '{print $1}'`
        done
    fi

    IFS=$ORIG_IFS
}

# Disable ZEROCONF, so that we dont get conflicting link-local routes in the future
disable_zeroconf() {

    if [ $MAJOR_OS == "SLES" ]
    then
        sed -i -e 's/LINKLOCAL_INTERFACES/#LINKLOCAL_INTERFACES/g' /etc/sysconfig/network/config
    else
        # Check to see if we've already disabled ZEROCONF
        ZEROCONF_DISABLED=`grep "NOZEROCONF" /etc/sysconfig/network`

        if [ "$ZEROCONF_DISABLED" != "NOZEROCONF=yes" ]
        then
            echo "NOZEROCONF=yes" >> /etc/sysconfig/network
        fi
    fi
}

# Echo the interface information to stdout
echo_interface_info() {
    get_correct_interface
    echo "INTERFACE INFORMATION:"
    IPADDR=`ifconfig $INTERFACE | awk 'NR==2{print $2}' | cut -c 6-20`
    NETMASK=`ifconfig $INTERFACE | awk 'NR==2{print $4}' | cut -c 6-20`

    #Make sure this works with other OSs....
    MAC=`ifconfig $INTERFACE | awk 'NR==1{print $5}'`

    echo "INTERFACE="$CORRECT_INTERFACE >&1
    echo "IPADDR="$IPADDR >&1
    echo "NETMASK="$NETMASK >&1
    echo "MAC="$MAC >&1
}

#This function is need on some linux distros because the dhcp client on that distro does
#not accept DHCP addresses that are link local addresses. IMM team guarantees that IMM
#will come up at a 169.254.X.118 address and that the subnets will start at 95 and increment from there.
ping_to_find_static_subnet(){
    PING_IFS=$IFS

    LIST_OF_SUBNETS=$IMM_SUBNET_STARTING_ADDR

    IFS=$(echo -en "\n\b;")

    for NUM in $LIST_OF_SUBNETS
    do
        echo "Trying "$NUM" subnet..."
        #No count is specified because ping will return a bad return code if the number of replies don't match the number sent.
        ifconfig $CORRECT_INTERFACE 169.254.$NUM.120 netmask 255.255.255.0 up
        ping -w 2 -I $CORRECT_INTERFACE 169.254.$NUM.118 > /dev/null

        if [ $? == 0 ]
        then
            #Successfully pinged IMM, remove this subnet form the list
            IFS=$PING_IFS
            IMM_SUBNET_STARTING_ADDR=`echo $IMM_SUBNET_STARTING_ADDR | sed 's/'$NUM';//g'`
            IMM_SUBNET=$NUM
            IMM_SUBNETS_USED=$IMM_SUBNETS_USED$IMM_SUBNET";"
            echo "The subnet for this address is "$IMM_SUBNET
            echo "The subnets used so far are "$IMM_SUBNETS_USED
            IFS=$PING_IFS
            return 0
        fi

    done
    IFS=$PING_IFS

    return 1
}

#This function may be used in place of the ping_to_find_static_subnet()
#However, it requires that the IMM enable the response to broadcast pings
# broadcast_ping_to_find_imm_subnet(){
#
#   for (( i=0; i<=2; i++ ))
#   do
#       TEMP_IMMADDR=`ping -c 1 -w 1 -I $CORRECT_INTERFACE -b 255.255.255.255 | grep icmp_seq | awk '{print $4}' | sed 's/://g'`
#
#       if [ -z TEMP_IMMADDR ]
#       then
#           PING_IFS=$IFS
#           IFS=$(echo -en "\n\b.")
#           IMM_SUBNET=`$TEMP_IMMADDR | awk '{print $3}'`
#           IMM_SUBNETS_USED=$IMM_SUBNETS_USED$IMM_SUBNET","
#           IFS=$PING_IFS
#           break
#       fi
#   done
#
#   #double check to make sure we aren't setting blank values on anything
#   if [ -z TEMP_IMMADDR ]
#   then
#       if [ -z IMM_SUBNET ]
#       then
#           exit 5
#       fi
#   fi
#
#   return 1
# }

ping_imm_in_all_used_subnets(){
    PING_IFS=$IFS
    IFS=$(echo -en "\n\b;")

    #echo interface and route info for debug
    ifconfig
    route -n

    tryNum=0
    while [ $tryNum -lt $IMM_DEVICE_COUNT ]
    do
        NET=`expr 95 + $tryNum`
        ping -c 1 -w 1 169.254.$NET.118 > /dev/null

        if [ $? != 0 ]
        then
            echo "Not able to ping the IMM at address 169.254."$NET".118"
            echo "We should have been able to reach this address."
            return 1
        else
            echo "Ping to 169.254."$NET".118 was good"
        fi
        tryNum=`expr $tryNum + 1`
    done

    if [ -z "$IMM_SUBNETS_USED" ]
    then
        echo "Addresses not set up by using ping...ping default address through all interfaces."
        ping_imm_via_cdc_interface
        return $?
    else
        return 0
    fi
}

bring_up_linux() {
    # Set bash internal field separator to comma
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")

    if [ $IMM_DEVICE_COUNT -gt 0 ] 
    then
        find_interface $MAC_ADDR
        if [ $IS_XEN == 0 ]
        then
        #We attempt to find the bridged interface after the normal usb interface so that the functions following
        #this one can use the IS_XEN value that is set in find_bridged_connection to determine whether to use
        #$INTERFACE or $BR_INTERFACE when writing the file.
            find_bridged_connection $MAC_ADDR
        fi

        if [ $RUN_STATIC_SETUP == 0 ]
        then
            echo "User specified static IP addressing..."
            check_for_previous_config_file
            write_config_file_static
            set_driver_alias_for_network_restart
            disable_zeroconf
            delete_link_local_routes
            bring_up_cdc
        else
            #if --staticip is not specified on the command line, we always attempt a DHCP setup then fall back to static address
            echo "DHCP IP addresssing being set up..."

                
            #It doesn't matter if we can talk to the IMM or not.Just because we can communicate with the IMM at
            #the default address does not mean that we can communicate over all of the interfaces. We have no choice
            #but to assume we cannot.
            check_for_previous_config_file
            write_config_file_dhcp
            bring_up_cdc

            if [ $? == 1 ]
            then
                #using ping to find the address of the IMM is ONLY used
                #on multi-node systems because on single node systems auto-conf
                #could cause us have the IMM at an address like 169.254.42.11 and
                #This would be a wait time or the user in the factorial measure.
                echo "Failed to bring up "$INTERFACE" via DHCP"
                CDC_ETHER_IPADDR=$CDC_ETHER_TEMP_IPADDR
                CDC_ETHER_NETMASK=$CDC_ETHER_TEMP_NETMASK

                #set up the interface with the temp ping address
                #check_for_previous_config_file
                #write_config_file_static
                #bring_up_cdc
                #if [ $? == 1 ]
                #then
                #    echo "Failed to bring up interface using ping static addressing"
                #    exit 4
                #fi

                #send out a ping and sets IMM_SUBNET to the right subnet
                ping_to_find_static_subnet

                if [ $? == 1 ]
                then
                    echo "Failed to find the IMM on multiple subnets."
                    ifdown $CORRECT_INTERFACE
                    exit 4
                fi

                #Now we have the correct subnet, so we write the correct address
                CDC_ETHER_IPADDR=169.254.$IMM_SUBNET.120
                CDC_ETHER_NETMASK=255.255.255.0

                #now we can write the config file with the correct address and netmask
                check_for_previous_config_file
                write_config_file_static
                bring_up_cdc
                if [ $? == 1 ]
                then
                    echo "Failed to bring up interface using ping static addressing"
                    exit 4
                fi
            else
                #delete subnet from IMM_SUBNET_STARTING_ADDR and add it to IMM_SUBNETS_USED
                IMM_SUBNET=`ifconfig $INTERFACE|grep 169.254|awk '{print $2}'|awk -F . '{print $3}'`
                IMM_SUBNET_STARTING_ADDR=`echo $IMM_SUBNET_STARTING_ADDR | sed 's/'$IMM_SUBNET';//g'`
                IMM_SUBNETS_USED=`echo $IMM_SUBNETS_USED | sed 's/'$IMM_SUBNET';//g'`
                IMM_SUBNETS_USED=$IMM_SUBNETS_USED$IMM_SUBNET";"
            fi
        fi
        echo_interface_info
   fi
    IFS=$TEMP_IFS
}

bring_up_vmware_3() {
    # Set bash internal field separator to comma
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")

    #We keep the for loop here because vmware 3 uses dmesg to find the interface, and because of this
    #it is possible to get multiple instances of the same interface back.

    vmware_3_find_interface $MAC_ADDR

    if [ $IMM_ALREADY_UP == 1 ] #Can't talk to IMM
    then
        echo "Unable to communicate with the IMM, configuring interface..."

        echo "DHCP IP addresssing being set up..."
        check_for_previous_config_file
        write_config_file_dhcp
        set_driver_alias_for_network_restart
        bring_up_cdc

        if [ $? == 1 ]
        then
            echo "DHCP setup failed, setting up static address."
            #Set the netmask broader in case of autoconf
            CDC_ETHER_NETMASK=$CDC_ETHER_TEMP_NETMASK
            check_for_previous_config_file
            write_config_file_static
            set_driver_alias_for_network_restart
            disable_zeroconf
            delete_link_local_routes
            bring_up_cdc
            if [ $? == 1 ]
            then
                echo "Static setup failed."
                exit 4
            fi
        fi
    fi
    echo_interface_info

    #we can break here because only single node is supported
    #and setup worked or the connection was already enabled.
}

bring_up_vmware_4(){
    # No need for write_config_file on VMWare 4, esxcfg-vswitch and esxcfg-vswif write their own configs
    # No need for disable_zeroconf on VMWare 4, esxcfg-vswif takes care of the unneeded link-local routes

    #Look for previous installations of the devices that use the IBM_CDC_PG port group and delete them
    vmware4_delete_previous_interfaces
    echo "Pausing for 5 seconds to let system quiesce..."
    sleep 5


    #echo "#IMM_DRIVER_STATUS=1" > $VMWARE_4_TEMP_FILE

    find_interface $MAC_ADDR

    echo "Bringing up interface via DHCP"
    vmware_4_bring_up_cdc DHCP
    if [ $? == 1 ]
    then
        CDC_ETHER_NETMASK=$CDC_ETHER_TEMP_NETMASK
        vmware_4_bring_up_cdc
    fi

    echo_interface_info
    vmware_4_imm_already_up_get_vswif_interface
}

bring_up_vmware() {
    # Set bash internal field separator to comma
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")

    if [ $VER == "3" ]
    then
        bring_up_vmware_3
    elif [ $VER == 4 ]
    then
        bring_up_vmware_4
    fi
    IFS=$TEMP_IFS
}


bring_up_cdc_by_mac(){
    #If the interface can ping  IMM  --> Do Nothing
    #If the interface is up and more than 1 IMM shows --> re-write all config files for DHCP (Major OS != VMWARE --> if DHCP fails attempt to
    #   ping individual subnets and statically address.)
    #If the interface is down and only 1 IMM shows --> DHCP setup, unless Static setup flag specified. (Major OS != VMWARE --> If DHCP fails,
    #   attempt to ping individual subnets and statically address.)
    #If the interface is down and more than 1 IMM shows --> DHCP setup for all config files. (Major OS != VMWARE --> If DHCP fails attempt to
    #   ping individual subnets and statically address.)

    #check if MAC specifyed is one of our usb interface
    check_if_usbmac_exist $MAC_ADDR
    if [ $? != 0 ]
    then
        echo "cannot find mac as usb interface." >&1
    	exit 8
    fi	
    ######
    # If the driver does not exist, we need to install in hand
    ######
    if [ $IMM_DRIVER_STATUS == 0 ]
    then
        load_driver
    fi

    delete_link_local_routes
    if [ $MAJOR_OS != VMWARE ]
    then
        bring_up_linux
    else
        bring_up_vmware
    fi

    # Drive some data over CDC interface.
    # (IMM hardware switches from "OS Booting" to "OS Booted" when traffic is seen on this interface in MCP.)
	
    # check usb network interface status
    # ping_imm_via_mac 	
    # if [ $? != 0 ]
    # then
    #      echo "Not able to successfully ping the IMM via MAC."
    #     exit 3
    #  fi

    #Ping reached IMM successfully, exit with Success
    echo "Exiting Successfully."
    exit 0
}

bring_up_all_cdc()
{
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")
	
    echo "begin to bring up all cdc..."
	
	######
    # If the driver does not exist, we need to install in hand
    ######
    if [ $IMM_DRIVER_STATUS == 0 ]
    then
        load_driver
    fi
	
	delete_link_local_routes
	
    for MAC in  $IMM_MACADDR_STRING
    do
        MAC_ADDR=$MAC
        
        if [ $MAJOR_OS != VMWARE ]
        then
            bring_up_linux
        else
            bring_up_vmware
        fi

        # Drive some data over CDC interface.
        # (IMM hardware switches from "OS Booting" to "OS Booted" when traffic is seen on this interface in MCP.)
        # check usb network interface status
        #ping_imm_via_mac 	
        #if [ $? != 0 ]
        #then
        #    echo "Not able to successfully ping the IMM via MAC."
        #    exit 3
        #fi

        #Ping reached IMM successfully, exit with Success
        echo "Successfully bring up "$MAC_ADDR
    done

    IFS=$TEMP_IFS
    echo "success to bring up all cdc"
    exit 0
}

check_if_usbmac_exist()
{
	
    CUR_MAC=$1
    TEMP_IFS=$IFS
    IFS=$(echo -en ",")
    exist=1
	
    echo "begin to find if MAC " $CUR_MAC " exist..."
	
    for MAC in  $IMM_MACADDR_STRING
    do
        if [ "$CUR_MAC" == "$MAC" ]
        then
            echo "success to find mac "$CUR_MAC
            exist=0
            break
        fi	
    done
	
    if [ "$exist" == "1" ]
    then
        echo "fail to find mac "$CUR_MAC
    fi	

    IFS=$TEMP_IFS
    return $exist
}

################################ MAIN ######################################
    ARGS=$@
    ARGS_COUNT=$#

    # Start the log
    echo -en "\n\n"  `date` "\n"
    echo cdc_interface VER 1.0.6

    if [ "$ARGS" == "-h" ] || [ "$ARGS" == "--help" ]
    then
        echo "--staticip  MAC    static bring up interface specified by MAC"
        echo "--restore          bring down all cdc interface"
        echo "--bringdown MAC    bring down interface specified by MAC"
        echo "--num FILE         get usb device count, and write MACs to FILE"
        echo "--bringup MAC      bring up interface specified by MAC"
        echo "--nodes nodes      check nodes number"
				echo "--staticip         bring up all cdc interface by static ip"
				echo "--get-vswif-mac MAC FILE     get vswif mac address of MAC, write to FILE"
				echo "NULL               bring up all cdc interface by dhcp"
        exit 0
    fi		

    detect_os_variant

    #Check if driver is currently loaded before doing anything else
    get_driver_status

    #Unload driver, then reload it to make sure it loads properly for VMWare, then get MAC addresses
    get_mac_addr

    #Parse the command line and execute as instructed
    parse_command_line_args $ARGS

    bring_up_all_cdc

    exit 0

