export function buildInstallProfilePromptPlan({ profiles = [], manifest = null } = {}) {
	const activeProfile = profiles.find((profile) => profile.selected) || profiles[0] || null;
	const manifestProfileName = manifest?.profileName;

	if (manifestProfileName && profiles.some((profile) => profile.name === manifestProfileName)) {
		return {
			kind: 'reuse-installed',
			profileName: manifestProfileName,
			profileOptions: {
				profileStrategy: 'existing',
				profileName: manifestProfileName,
			},
		};
	}

	if (profiles.length <= 1 && activeProfile) {
		return {
			kind: 'single-profile',
			currentProfileName: activeProfile.name,
			defaultCloneName: `${activeProfile.name} - DJI Mic Dictation`,
			profileOptions: {
				profileStrategy: 'active',
			},
		};
	}

	return {
		kind: 'multi-profile',
		activeProfileName: activeProfile?.name || null,
	};
}
