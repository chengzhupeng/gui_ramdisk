#!/bin/bash
# version 2018-06-19
# author  pengcz
#
#
#
# check the network  ping
#ping -c 1 172o.20.0.1 >/dev/null
dbus-luncher gsettings set org.gnome.desktop.session idle-delay 0

#
##
PID=$(pgrep gnome-session)
export DBUS_SESSION_BUS_ADDRESS=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$PID/environ|cut -d= -f2-)
dbus-luncher gsettings set  org.gnome.desktop.lockdown disable-lock-screen true
##
ip a | grep '172.20' >/dev/null
if [ $? -ne 0 ];then
    systemctl  restart NetworkManager
    sleep 5
fi

ping -c 1 172.20.0.1 >/dev/null
if [ $? -ne 0 ];then
   err_detect=1
else
    mount  | grep '172.20.0.1' >/dev/null
    # mount -t cifs  //172.20.0.1/tftpboot /tftpboot  -o username=plclient%client  for RHEL6 only
    if  [ $? -ne 0 ] ;then
          mount -t cifs  //172.20.0.1/tftpboot /tftpboot  -o username=plclient,password=client
    fi
fi

#check the samba mount in AVT or FVT
mount  | grep '172.20.0.1' >/dev/null
if [ $? -ne 0 ];then
   err_detect=1
fi

#check the mount flag in the remote server

if [ ! -e /tftpboot/mntflag ];then
    err_detect=1
fi
SN=`dmidecode -s system-serial-number`
export SN
#
echo $SN |grep 'To Be Filled By O.E.M' >/dev/null
if [ $? -eq 0 ] ; then
     err_detect=1
fi
###do the pre_check before show the gui
### do the software install / enviroment settings here for improvement
###
if [ -e /tftpboot/pre_check.sh ];then
     bash /tftpboot/pre_check.sh
fi
####

#check to see if the system-serial-number is not set by the BIOS /UEFI
#
if [ "X${err_detect}" == "X1"  ];then
    /usr/bin/python3.6 /usr/bin/show_startup_error.py
    exit 1
fi
mkdir -p  /tftpboot/logs/${SN}/
cd  /tftpboot/logs/${SN}/
#
#
# if all above is ready , then we can think that the network ,the samba service are work fine
# we will start to test in GUI
#
# check the if HDD test workstation or not ,if yes ,then the MTSN will have the HDD.WS file
#iif [ -e /tftpboot/logs/${SN}/HDD.WS ];then
#       if [ -e /tftpboot/scripts/hdd.py ];then
#           /usr/bin/python3 /tftpboot/scripts/hdd.py
#       elif [   -e /usr/bin/hdd.py ];then
#             /usr/bin/python3  /usr/bin/hdd.py
#       else
#            echo -e " not HDD python Scripts found ,please check"
#            echo -e " not HDD python Scripts found ,please check"  >>/tmp/tester.log
#            exit 1
#       fi
#fi
#
# if [ -e /tftpboot/logs/${SN}/retry_avt ];then
# no retry need in AVT and FVT
export MFGER="TESTCODE"
#
#
if [ -e /tftpboot/logs/${SN}/CODEZIP.INI ];then
	CODE=`cat /tftpboot/logs/${SN}/CODEZIP.INI | cut -d= -f2`
	python3.6 ${CODE}
#check the AVT.DONE to see if the first time to start the test or not
if [ ! -e /tftpboot/logs/${SN}/AVT.DONE ];then
       if [ -e /tftpboot/${SN}/${MFGER}.INI ];then
           CODE=`cat /tftpboot/logs/${SN}/${MFGER}.INI | cut -d= -f2`
           /usr/bin/python3.6 ${CODE}
       elif  [ -e /tftpboot/logs/${SN}/avt.py ];then
           /usr/bin/python3.6 /tftpboot/logs/${SN}/avt.py
       elif [ -e /tftpboot/scripts/avt.py ]; then
           /usr/bin/python3.6 /tftpboot/scripts/avt.py
       else
            echo -e " not AVT python Scripts found ,please check"
            echo -e " not AVT  python Scripts found ,please check"  >>/tmp/tester.log
            no_scripts=1
        fi


elif [ -e /tftpboot/logs/${SN}/NOS.DONE ];  then
        if [ -e /tftpboot/${SN}/${MFGER}.INI ];then
                CODE=`cat /tftpboot/${MFGER}.INI | cut -d= -f2`
                /usr/bin/python3.6 ${CODE}
        elif  [ -e /tftpboot/log/${SN}/fvt.py ] ; then
                /usr/bin/python3.6 /tftpboot/logs/${SN}/fvt.py
        elif [ -e /tftpboot/scripts/fvt.py ]; then
                /usr/bin/python3.6 /tftpboot/scripts/fvt.py
        else
                echo -e " not FVT python Scripts found ,please check"
                echo -e " not FVT  python Scripts found ,please check"  >>/tmp/tester.log
                no_scripts=1
        fi

else
        echo -e "NO specify  SCRIPT FOUND IN  /tftpboot/scripts DIR"
        echo -e "NO specify  SCRIPT FOUND IN  /usr/bin/ DIR"
        echo -e "CHECK WITH TE FOR DEBUG..."

fi
if [ "x${no_scripts}" == "x1" ];then
        /usr/bin/python3 /usr/bin/show_no_avt_fvt.py
        exit 1
fi
