' Launch RAMMapTray.ps1 with no console window (0 = hidden, False = do not wait)
Set sh = CreateObject("WScript.Shell")
base = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & base & "RAMMapTray.ps1""", 0, False
