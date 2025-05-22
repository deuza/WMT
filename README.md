
[![GitHub release](https://img.shields.io/github/v/release/DeuZa/WMT?label=release)](https://github.com/DeuZa/WMT[/releases)
[![GitHub last commit](https://img.shields.io/github/last-commit/DeuZa/wmt)](https://github.com/DeuZa/wmt/commits/main)
[![License: CC0](https://img.shields.io/badge/license-CC0_1.0-lightgrey.svg)](https://creativecommons.org/publicdomain/zero/1.0/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue)](https://docs.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20WSL2-green)](https://learn.microsoft.com/en-us/windows/wsl/)

# 🐧 WSL2 Management Tool (WMT) 🐧

Clone, export, import your WSL2 distributions — with optional compression of `.tar` files into `.zip` files.

---

## 🚀 Features

- Simple graphical interface in WinForms
- Cloning of a WSL2 distribution with choice of folder
- Export `.tar` with automatic compression option to `.zip`
- Import of a `.tar` or `.zip` to a new name/disk
- Automatic checks (disk space, existing name, etc.)
- 7-Zip support if available, otherwise native .NET fallback

---

## 📦 Installation

No installation required! Download the `.ps1` script, run it with PowerShell (preferably as an administrator):

```powershell
.\WMT.ps1
```

### Running the Script with "Mark of the Web" policies :

If you encounter issues running `WMT.ps1` due to PowerShell execution policies, you might need to:

1.  **Unblock the file:**
    After downloading and extracting the script, right-click on `WMT.ps1`, go to Properties, and if you see an "Unblock" button or checkbox at the bottom of the General tab, click it and then OK.
    Alternatively, from PowerShell:
    ```powershell
    Unblock-File -Path ".\WMT.ps1"
    ```

2.  **Set Execution Policy for the current process (recommended for ease of use):**
    Open PowerShell, navigate to the script's directory, and run:
    ```powershell
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\WMT.ps1
    ```
    This change only affects the current PowerShell session.

## ⚠️  Requires WSL2 to be active with at least one distro installed.

## 🛠️ Dependencies (optional)

- 7-Zip (for more efficient compression)
- PowerShell ≥ 5.1 (pre-installed on Win10/11)
- Windows 10 / 11 with WSL2 enabled

---

## 💡 Tips

- .zip compression is automatic after export if the option is checked.
- The import directly accepts .zip files (unzipped in the background).
- By default, clones are exported to %TEMP%\WMT_Exports_Temp.

---

## ✅ Roadmap (v0.1.x)

-  Unified GUI interface
-  Command line mode (headless)
-  Auto-detection of corruption in archives
-  Batch mode for scheduled backups

---

## 🔓 Licence

CC0 1.0 Universal :
https://creativecommons.org/publicdomain/zero/1.0/

---

With ❤️  by  DeuZa ...
