import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

const OK_STATUSES = new Set(['granted', 'enabled', 'ok']);
const FAIL_STATUSES = new Set(['denied', 'disabled', 'missing']);

const PERMISSION_CHECK_SCRIPT = String.raw`
import ctypes
import json
import pathlib
import plistlib
import sqlite3
import sys

home_dir = pathlib.Path(sys.argv[1])
system_tcc_path = pathlib.Path('/Library/Application Support/com.apple.TCC/TCC.db')

items = []

def add_item(key, label, status, source, detail=None):
    items.append({
        'key': key,
        'label': label,
        'status': status,
        'source': source,
        'detail': detail,
    })

def tcc_status(service, clients):
    if not system_tcc_path.exists():
        return ('unknown', 'tcc_db_missing')
    try:
        conn = sqlite3.connect(str(system_tcc_path))
        cur = conn.cursor()
        for client in clients:
            row = cur.execute(
                'SELECT auth_value FROM access WHERE service = ? AND client = ? ORDER BY last_modified DESC LIMIT 1',
                (service, client),
            ).fetchone()
            if row is None:
                continue
            auth_value = row[0]
            if auth_value == 2:
                return ('granted', client)
            if auth_value == 0:
                return ('denied', client)
            return ('unknown', f'{client}:{auth_value}')
        return ('unknown', 'no_record')
    except Exception as error:
        return ('unknown', type(error).__name__)
    finally:
        try:
            conn.close()
        except Exception:
            pass

def read_plist(path):
    if not path.exists():
        return None
    try:
        return plistlib.loads(path.read_bytes())
    except Exception:
        return None

try:
    application_services = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    application_services.AXIsProcessTrusted.restype = ctypes.c_bool
    add_item(
        'accessibilityCurrentSession',
        'Current session accessibility',
        'granted' if application_services.AXIsProcessTrusted() else 'denied',
        'ax_api',
    )
except Exception as error:
    add_item('accessibilityCurrentSession', 'Current session accessibility', 'unknown', 'ax_api', type(error).__name__)

try:
    core_graphics = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    core_graphics.CGPreflightPostEventAccess.restype = ctypes.c_bool
    add_item(
        'postEventCurrentSession',
        'Current session event posting',
        'granted' if core_graphics.CGPreflightPostEventAccess() else 'denied',
        'coregraphics_api',
    )
except Exception as error:
    add_item('postEventCurrentSession', 'Current session event posting', 'unknown', 'coregraphics_api', type(error).__name__)

karabiner_input_status, karabiner_input_detail = tcc_status('kTCCServiceListenEvent', ['org.pqrs.Karabiner-Core-Service'])
add_item('karabinerInputMonitoring', 'Karabiner input monitoring', karabiner_input_status, 'tcc_db', karabiner_input_detail)

assistant_support = read_plist(home_dir / 'Library/Preferences/com.apple.assistant.support.plist') or {}
hitoolbox = read_plist(home_dir / 'Library/Preferences/com.apple.HIToolbox.plist') or {}

dictation_enabled = assistant_support.get('Dictation Enabled')
dictation_source = 'com.apple.assistant.support'
if dictation_enabled is None:
    dictation_enabled = hitoolbox.get('AppleDictationAutoEnable')
    dictation_source = 'com.apple.HIToolbox'

if dictation_enabled is None:
    add_item('dictation', 'macOS Dictation', 'unknown', 'preferences', 'no_preference_key')
else:
    add_item(
        'dictation',
        'macOS Dictation',
        'enabled' if bool(dictation_enabled) else 'disabled',
        'preferences',
        dictation_source,
    )

print(json.dumps({'items': items}))
`;

function normalizePermissionReport(report = {}) {
	const items = Array.isArray(report.items)
		? report.items.map((item) => ({
				key: item.key || 'unknown',
				label: item.label || item.key || 'Permission',
				status: item.status || 'unknown',
				source: item.source || null,
				detail: item.detail || null,
			}))
		: [];

	let status = report.status;
	if (!status) {
		if (items.length === 0 || items.every((item) => item.status === 'unknown')) {
			status = 'unknown';
		} else if (items.every((item) => OK_STATUSES.has(item.status))) {
			status = 'ok';
		} else if (items.some((item) => FAIL_STATUSES.has(item.status))) {
			status = 'action_required';
		} else {
			status = 'unknown';
		}
	}

	return { status, items };
}

function unknownPermissionReport(detail) {
	return normalizePermissionReport({
		status: 'unknown',
		items: [
			{
				key: 'permissionInspection',
				label: 'Permission inspection',
				status: 'unknown',
				source: 'inspector',
				detail,
			},
		],
	});
}

export async function detectPermissions(runtime) {
	if (runtime.env.DJI_PERMISSION_CHECK_JSON) {
		return normalizePermissionReport(JSON.parse(runtime.env.DJI_PERMISSION_CHECK_JSON));
	}

	try {
		const { stdout } = await execFile(runtime.env.PYTHON3_BIN || 'python3', ['-c', PERMISSION_CHECK_SCRIPT, runtime.homeDir], {
			env: runtime.env,
		});
		return normalizePermissionReport(JSON.parse(stdout));
	} catch (error) {
		return unknownPermissionReport(error.code || error.message || 'permission_check_failed');
	}
}
