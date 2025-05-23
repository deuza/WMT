![GitHub release](https://img.shields.io/github/v/release/DeuZa/WMT?label=release&style=plastic)
[![GitHub last commit](https://img.shields.io/github/last-commit/DeuZa/WMT?style=plastic)](https://github.com/DeuZa/WMT/commits/main)
![Status](https://img.shields.io/badge/stability-solid-green?style=plastic)
[![License: CC0](https://img.shields.io/badge/license-CC0_1.0-lightgrey.svg?style=plastic)](https://creativecommons.org/publicdomain/zero/1.0/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?style=plastic)](https://docs.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20WSL2-green?style=plastic)](https://learn.microsoft.com/en-us/windows/wsl/)
![GUI](https://img.shields.io/badge/UI-WinForms-7a7a7a?style=plastic)
![GitHub Release Date](https://img.shields.io/github/release-date/deuza/WMT)
![GitHub commit activity](https://img.shields.io/github/commit-activity/t/deuza/WMT)
![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=flat-square\&logo=gnu\&logoColor=white)
![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)

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

### 📸 Snapshots

Here's an overview of the WSL interface :

|           |           |           |
|-----------|-----------|-----------|
| ![01](https://github.com/deuza/WMT/releases/download/v0.1.1/01.png) | ![02](https://github.com/deuza/WMT/releases/download/v0.1.1/02.png) | ![03](https://github.com/deuza/WMT/releases/download/v0.1.1/03.png) |
| ![04](https://github.com/deuza/WMT/releases/download/v0.1.1/04.png) | ![05](https://github.com/deuza/WMT/releases/download/v0.1.1/05.png) | ![06](https://github.com/deuza/WMT/releases/download/v0.1.1/06.png) |
| ![07](https://github.com/deuza/WMT/releases/download/v0.1.1/07.png) | ![08](https://github.com/deuza/WMT/releases/download/v0.1.1/08.png) | ![09](https://github.com/deuza/WMT/releases/download/v0.1.1/09.png) |
| ![10](https://github.com/deuza/WMT/releases/download/v0.1.1/10.png) | ![11](https://github.com/deuza/WMT/releases/download/v0.1.1/11.png) | |


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
