using UnrealBuildTool;
using System.Collections.Generic;

public class HalfSwordUE5EditorTarget : TargetRules
{
	public HalfSwordUE5EditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_4;
		ExtraModuleNames.Add("HalfSwordUE5");
	}
}
