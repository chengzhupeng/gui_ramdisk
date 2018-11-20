#!/usr/bin/python3 
#
import tkinter as tk
import sys
wm       = tk.Tk()
wm.title("！！！错误，不能进行测试！！！！")
wm.resizable(0,0)
show_err = """

	在开始测试的时候发现问题，请按下面步骤手工检查

           
           如果出现这在这里，说明上面的检查是没有问题的，只是找不到测试脚本了呵
           请检查 avt.py 与 fvt.py 或者其他脚本是否正常，谢谢！！！

                                                                    Version: 2018-06-26

            """
label_show_err  = tk.Label(wm,text=show_err,bg="yellow",font=('cjkuni',20),anchor='w',justify='left')
button_quit = tk.Button(wm,text="退    出",command=sys.exit,anchor = "center",justify="center",font=('cjkuni',18,'bold'),relief="raised",bg="#DB7093")
label_show_err.pack()
button_quit.pack(fill="x")
wm.mainloop()
