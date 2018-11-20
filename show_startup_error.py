#!/usr/bin/python3 
#
import tkinter as tk
import sys
wm       = tk.Tk()
wm.title("！！！错误，不能进行测试！！！！")
wm.resizable(0,0)
show_err = """

	在开始测试的时候发现问题，请按下面步骤手工检查

	1： 检查IP地址正确与否，可以用ip a命令检查
	2： 检查网络通顺与否，可以ping 172.20.0.1来检查
	3： 检查samba挂载成功与否，可用mount | grep '172.20'来检查
	4： 检查硬件有没有流水号，一些产品会没有流水号呵！检查方法可以是         
  	  #dmidecode -s system-serial-number
	5： 其他检查，如交换机，网络连接等
	6：如按上面处理后还有问题，请联系工程师解决

                                                                    Version: 2018-06-19

            """
label_show_err  = tk.Label(wm,text=show_err,bg="yellow",font=('cjkuni',20),anchor='w',justify='left')
button_quit = tk.Button(wm,text="退    出",command=sys.exit,anchor = "center",justify="center",font=('cjkuni',18,'bold'),relief="raised",bg="#DB7093")
label_show_err.pack()
button_quit.pack(fill="x")
wm.mainloop()
