# Windows profile installer

`Nikitid-IKEv2-Setup.exe` installs, updates, verifies, and removes VPNv2 XML
profiles for the current Windows user. It can receive a profile on the command
line, discover a single adjacent `*.vpnv2.xml`, or let the user choose any XML
through the standard file picker. The application uses the in-box VPNv2 WMI
Bridge provider directly and doesn't invoke PowerShell or leave a service or
scheduled task behind.

The executable targets .NET Framework 4.8 and runs on supported Windows 10 and
Windows 11 installations. Build it with Mono:

```sh
./windows-profile-installer/build.sh
./windows-profile-installer/test.sh
```

The prebuilt executable shipped in the OpenWrt package must be rebuilt whenever
the source or `app-icon.svg` changes. Regenerate `app.ico` from the SVG before
building. A production release should be Authenticode-signed before
packaging; signing the generic executable doesn't expose profile credentials.
