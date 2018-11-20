#!/bin/bash
if [ -z $1 ];then
	echo -e "\033[31mPLEASE SPECIFY THE TARGET CHROOT DIR"
	echo -e "Usage:"
	echo -e "      /install/netboot/xxxx"
	echo -e "exit...\033[0m"
	exit 1
fi
if [ ! -d  $1 ];then
	echo -e "\033[31mTarget Dir is not exist ,pleae check before continue..."
	echo -e "exit...\033[0m"
	exit 2
fi
echo  $1 | grep 'rootimg' >/dev/null
if [ $? -ne 0 ];then
	echo -e "\033[31mWrong chroot dir"
	echo -e "Usage:"
	echo -e "   /install/netboot/rhels7.5/x86_64/small/rootimg/"
	echo -e "exit...\033[0m"
	exit 3
fi
mkdir -p $1/root/.config/autostart/
cp gui.desktop $1/root/.config/autostart/
cp start_gui.sh $1/usr/bin/
cp show_no_avt_fvt.py  $1/usr/bin/
cp show_startup_error.py  $1/usr/bin/
cp asu64  $1/usr/bin/
cp cdc_interface.sh  $1/usr/bin/
cp build_gsettings.sh  $1/root/
