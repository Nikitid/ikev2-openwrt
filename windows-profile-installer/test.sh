#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

mcs -nologo -sdk:4.8 -optimize+ -target:exe \
	-main:Nikitid.IkeV2ProfileInstaller.ProfileDocumentTests \
	-r:System.dll -r:System.Core.dll -r:System.Drawing.dll \
	-r:System.Management.dll -r:System.Windows.Forms.dll -r:System.Xml.dll \
	-out:"$work/profile-tests.exe" \
	"$root/Program.cs" "$root/tests/ProfileDocumentTests.cs"
mono "$work/profile-tests.exe"
