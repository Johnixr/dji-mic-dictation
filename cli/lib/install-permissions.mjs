const SATISFIED_STATUSES = new Set(['granted', 'enabled', 'ok']);

export const INSTALL_BLOCKING_PERMISSION_KEYS = new Set([
	'accessibilityCurrentSession',
	'postEventCurrentSession',
]);

export const INSTALL_REMINDER_PERMISSION_KEYS = new Set([
	'accessibilityCurrentSession',
	'postEventCurrentSession',
]);

export function isPermissionSatisfied(status) {
	return SATISFIED_STATUSES.has(status);
}

function getInstallPermissionIssues(permissions, relevantKeys) {
	if (!permissions || permissions.status === 'ok') {
		return [];
	}
	return (permissions.items || []).filter(
		(item) => relevantKeys.has(item.key) && !isPermissionSatisfied(item.status),
	);
}

export function getBlockingPermissionIssues(permissions) {
	return getInstallPermissionIssues(permissions, INSTALL_BLOCKING_PERMISSION_KEYS);
}

export function getInstallPermissionReminderIssues(permissions) {
	return getInstallPermissionIssues(permissions, INSTALL_REMINDER_PERMISSION_KEYS);
}

export function filterInstallPermissionReport(permissions) {
	if (!permissions) {
		return { status: 'ok', items: [] };
	}
	const items = (permissions.items || []).filter((item) => INSTALL_REMINDER_PERMISSION_KEYS.has(item.key));
	if (items.length === 0) {
		return { status: 'ok', items: [] };
	}
	if (items.every((item) => item.status === 'unknown')) {
		return { status: 'unknown', items };
	}
	if (items.every((item) => isPermissionSatisfied(item.status))) {
		return { status: 'ok', items };
	}
	return { status: 'action_required', items };
}
