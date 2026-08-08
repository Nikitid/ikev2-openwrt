#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source="$root/windows-profile-installer/Program.cs"
binary="$root/windows-profile-installer/bin/Nikitid-IKEv2-Setup.exe"

[ -s "$binary" ] || {
	printf 'Windows profile installer binary is missing\n' >&2
	exit 1
}

# A PE executable starts with MZ. Keep this deliberately portable: od is
# available both in developer environments and the CI runner.
[ "$(od -An -tx1 -N2 "$binary" | tr -d ' \n')" = 4d5a ] || {
	printf 'Windows profile installer is not a PE executable\n' >&2
	exit 1
}

grep -Fq 'SecurityElement.Escape(document.Xml)' "$source"
grep -Fq 'MDM_VPNv2_01' "$source"
grep -Fq 'Verb = "runas"' "$source"
grep -Fq 'profile.Put()' "$source"
grep -Fq 'Windows не вернула установленный профиль' "$source"
grep -Fq 'Icon.ExtractAssociatedIcon(Application.ExecutablePath)' "$source"
grep -Fq 'DarkTitleBar.Apply(Handle)' "$source"
grep -Fq 'BackColor = AppPalette.Surface;' "$source"
grep -Fq 'Panel card = new Panel' "$source"
grep -Fq 'nameInput.Controls.Add(nameTextBox)' "$source"
grep -Fq 'card.Controls.Add(nameInput)' "$source"
grep -Fq 'AppPalette.Background' "$source"
grep -Fq 'SetStatus(message, AppPalette.Success)' "$source"
grep -Fq 'class ModernButton' "$source"
grep -Fq 'OpenFileDialog' "$source"
grep -Fq 'Выберите XML-профиль, чтобы продолжить.' "$source"
grep -Fq 'installButton.Enabled = true;' "$source"
grep -Fq 'MakeButton("Журнал", 44, 336, 136' "$source"
grep -Fq 'MakeButton("Открыть VPN", 209, 336, 136' "$source"
grep -Fq 'MakeButton("Удалить", 374, 336, 136' "$source"
grep -Fq 'MakeButton("Установить", 540, 336, 136' "$source"
grep -Fq 'class WorkerOperation' "$source"
grep -Fq 'EnableRaisingEvents = true' "$source"
grep -Fq 'CompleteWorker(operation, capturedPath, exitCode)' "$source"
grep -Fq 'WindowStyle = ProcessWindowStyle.Hidden' "$source"
grep -Fq -- '-win32icon:' "$root/windows-profile-installer/build.sh"

if grep -Fq 'button.Region =' "$source"; then
	printf 'Windows profile installer still clips native button borders\n' >&2
	exit 1
fi

if grep -Fq 'BackdropPanel backdrop' "$source"; then
	printf 'Windows profile installer still creates the removed inset backdrop\n' >&2
	exit 1
fi

if grep -Fq 'DNS-политика действует только' "$source"; then
	printf 'Windows profile installer still contains the removed DNS notice\n' >&2
	exit 1
fi

if grep -Eqi 'powershell|scheduledtask|create(service|process)' "$source"; then
	printf 'Windows profile installer gained an external script or background worker\n' >&2
	exit 1
fi

printf 'Windows profile installer tests OK\n'
