-- SeekBalance 一键卸载程序
-- 双击运行，按提示操作。删除 App 本身 + 它自己的偏好设置/缓存，绝不碰 dsh 的数据（~/.dsh）。

set appName to "SeekBalance"
set bundleID to "local.seekbalance"
set homePath to POSIX path of (path to home folder)

-- 1. 确认
set theAnswer to button returned of (display dialog "真的要卸载 SeekBalance 吗？" & return & return & "将删除：" & return & "• 应用程序：/Applications/SeekBalance.app" & return & "• 它的偏好设置与缓存（~/Library 下的相关文件）" & return & return & "不会删除 dsh 的数据（~/.dsh），请放心。" & return & return & "若提示输入密码，请输入你的开机密码。" buttons {"取消", "卸载"} default button "卸载" with icon caution with title "卸载 SeekBalance")

if theAnswer is not "卸载" then
  return
end if

-- 2. 先退出正在运行的 SeekBalance（两种运行位置都处理）
try
  do shell script "pkill -x SeekBalance; pkill -f '/Applications/SeekBalance.app/Contents/MacOS/SeekBalance'; pkill -f 'dist/SeekBalance.app/Contents/MacOS/SeekBalance'; true"
end try
delay 1

-- 3. 删除文件清单（都是绝对路径，管理员权限下也不会跑偏）
set rmCmd to "rm -rf " & ¬
  quoted form of "/Applications/SeekBalance.app" & " " & ¬
  quoted form of (homePath & "Library/Preferences/" & bundleID & ".plist") & " " & ¬
  quoted form of (homePath & "Library/Preferences/" & bundleID & ".plist.lockfile") & " " & ¬
  quoted form of (homePath & "Library/Caches/" & bundleID) & " " & ¬
  quoted form of (homePath & "Library/Application Support/" & appName) & " " & ¬
  quoted form of (homePath & "Library/Saved Application State/" & bundleID & ".savedState") & " " & ¬
  quoted form of (homePath & "Library/HTTPStorages/" & bundleID) & " " & ¬
  quoted form of (homePath & "Library/WebKit/" & bundleID) & "; true"

-- 4. 用管理员权限删除（确保 /Applications 里的应用能删掉）；用户取消密码时退回普通权限再试
try
  do shell script rmCmd with administrator privileges
on error errMsg number errNum
  try
    do shell script rmCmd
  on error
    display dialog "删除时遇到问题：" & errMsg & return & "你可以手动把 /Applications/SeekBalance.app 拖进废纸篓。" buttons {"知道了"} default button "知道了" with icon stop
    return
  end try
end try

-- 5. 检查结果并汇报
try
  do shell script "test ! -e /Applications/SeekBalance.app && echo gone || echo still"
  set checkResult to result
on error
  set checkResult to "still"
end try

if checkResult is "still" then
  display dialog "卸载没完全成功：/Applications/SeekBalance.app 还在。" & return & "请手动把它拖进废纸篓。" buttons {"知道了"} default button "知道了" with icon stop
else
  display dialog "✅ 卸载完成！" & return & return & "SeekBalance 程序和它的偏好设置、缓存都已删除。" & return & "dsh 的数据（~/.dsh）没有被动过。" buttons {"好"} default button "好" with icon note with title "卸载完成"
end if
