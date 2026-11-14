@echo off
setlocal EnableExtensions
title PD2 Music System build - leave this window open
set "ROOT=%~dp0"
set "LOG=%ROOT%build_log.txt"
set "PATH=%USERPROFILE%\.cargo\bin;%ProgramFiles%\Git\cmd;%PATH%"
echo ==== build started %date% %time% > "%LOG%"
echo Building the PD2 Music System native DLL. This takes a while the first time (10-30 min).
echo If a GitHub sign-in window appears, sign in - it's needed for the Unreal source.
echo.

call :step "tools" || goto fail
where git >> "%LOG%" 2>&1 || (echo ERROR: git not found>>"%LOG%" & goto fail)
where cargo >> "%LOG%" 2>&1 || (echo ERROR: rust/cargo not found>>"%LOG%" & goto fail)
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo ERROR: Visual Studio C++ tools not found>>"%LOG%" & goto fail)
echo VS: %VSDIR%>>"%LOG%"
set "CMAKE=%VSDIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
if not exist "%CMAKE%" (echo ERROR: VS cmake not found at %CMAKE%>>"%LOG%" & goto fail)
"%CMAKE%" --version >> "%LOG%" 2>&1
echo tools ok>>"%LOG%"

call :step "source" || goto fail
cd /d "%ROOT%"
if not exist "RE-UE4SS\.git" git clone https://github.com/UE4SS-RE/RE-UE4SS.git >> "%LOG%" 2>&1
cd /d "%ROOT%RE-UE4SS" || goto fail
git fetch --all >> "%LOG%" 2>&1
git checkout 0290bedac01f4acfdcbaa13c5a5a2fa14585a549 >> "%LOG%" 2>&1 || (echo ERROR: checkout failed>>"%LOG%" & goto fail)
echo Downloading submodules (GitHub sign-in may pop up)...
if exist "%ROOT%github_user.txt" set /p GHUSER=<"%ROOT%github_user.txt"
if not defined GHUSER set /p GHUSER=Type your GitHub username and press Enter: 
echo %GHUSER%> "%ROOT%github_user.txt"
echo Sign in to GitHub in the window that opens (needed for the Unreal source)...
git -c url."https://%GHUSER%@github.com/".insteadOf="git@github.com:" submodule update --init --recursive >> "%LOG%" 2>&1 || (echo ERROR: submodules failed - is GitHub linked to Epic and the invite accepted?>>"%LOG%" & goto fail)

echo Applying CasePreserving header fix...
powershell -NoProfile -Command "$f='%ROOT%RE-UE4SS\deps\first\Unreal\include\Unreal\NameTypes.hpp'; $t=[IO.File]::ReadAllText($f); $t=$t.Replace('ComparisonIndex = IndexParam;','ComparisonIndex = FNameEntryId::FromUnstableInt(IndexParam);').Replace('DisplayIndex = DisplayIndexParam;','DisplayIndex = FNameEntryId::FromUnstableInt(DisplayIndexParam);'); [IO.File]::WriteAllText($f,$t)" >> "%LOG%" 2>&1

powershell -NoProfile -Command "$f='%ROOT%RE-UE4SS\UE4SS\src\GUI\Dumpers.cpp'; $t=[IO.File]::ReadAllText($f); $t=$t.Replace('= name.GetDisplayIndex();','= name.GetDisplayIndex().ToUnstableInt();'); [IO.File]::WriteAllText($f,$t); $f='%ROOT%RE-UE4SS\UE4SS\src\GUI\LiveView.cpp'; $t=[IO.File]::ReadAllText($f); $t=$t.Replace('name.GetDisplayIndex());','name.GetDisplayIndex().ToUnstableInt());'); [IO.File]::WriteAllText($f,$t)" >> "%LOG%" 2>&1

call :step "configure" || goto fail
cd /d "%ROOT%"
"%CMAKE%" -B out -G "Visual Studio 18 2026" -A x64 >> "%LOG%" 2>&1 || (echo ERROR: cmake configure failed>>"%LOG%" & goto fail)

call :step "build" || goto fail
echo Compiling... (the long part)
"%CMAKE%" --build out --config CasePreserving__Shipping__Win64 --target PD2Jukebox >> "%LOG%" 2>&1 || (echo ERROR: build failed>>"%LOG%" & goto fail)

call :step "install" || goto fail
for /f "delims=" %%f in ('dir /s /b "out\PD2Jukebox.dll"') do set "DLL=%%f"
if not defined DLL (echo ERROR: PD2Jukebox.dll not found>>"%LOG%" & goto fail)
rem result: src\dist\main.dll - copy it to PD2MusicSystem\dlls\main.dll
mkdir "%ROOT%dist" 2>nul
copy /y "%DLL%" "%ROOT%dist\main.dll" >> "%LOG%" 2>&1 || (echo ERROR: copy to dist failed>>"%LOG%" & goto fail)
echo dll: %ROOT%dist\main.dll>> "%LOG%"
echo ==== BUILD OK %date% %time% >> "%LOG%"
echo.
echo Done! You can close this window.
exit /b 0

:step
echo [%~1] >> "%LOG%"
echo -- %~1
exit /b 0

:fail
echo ==== BUILD FAILED %date% %time% >> "%LOG%"
echo.
echo Something failed - see build_log.txt. You can close this window.
exit /b 1
