# Generates the vanilla item registry and creative tabs of mc_game from an
# extracted Minecraft client (decompiled sources plus assets), and copies the
# item and container textures into mc_game's materials.
#
#   powershell -File tools/content/generate_items.ps1 -MinecraftRoot <dir> [-SkipMaterials]
#
# Names are not written into the Lua output: each item row carries the
# Minecraft translation key, and the translations themselves come from
# tools/localization/generate_minecraft_lang.py.
param(
	[Parameter( Mandatory = $true )][string] $MinecraftRoot,
	[string] $RepositoryRoot,
	[switch] $SkipMaterials
)

$ErrorActionPreference = "Stop"
if ( -not $RepositoryRoot ) { $RepositoryRoot = ( Resolve-Path ( Join-Path $PSScriptRoot "..\.." ) ).Path }
$minecraftRoot = $MinecraftRoot
$gameRoot = Join-Path $RepositoryRoot "addons\mc_game"
$assetsRoot = Join-Path $minecraftRoot "assets\minecraft"
$itemsJavaPath = Join-Path $minecraftRoot "net\minecraft\world\item\Items.java"
$itemIdsPath = Join-Path $minecraftRoot "net\minecraft\references\ItemIds.java"
$blockItemIdsPath = Join-Path $minecraftRoot "net\minecraft\references\BlockItemIds.java"
$toolMaterialPath = Join-Path $minecraftRoot "net\minecraft\world\item\ToolMaterial.java"
$armorMaterialsPath = Join-Path $minecraftRoot "net\minecraft\world\item\equipment\ArmorMaterials.java"
$armorTypePath = Join-Path $minecraftRoot "net\minecraft\world\item\equipment\ArmorType.java"
$creativeTabsPath = Join-Path $minecraftRoot "net\minecraft\world\item\CreativeModeTabs.java"
$itemDefinitionRoot = Join-Path $assetsRoot "items"
$itemTextureRoot = Join-Path $assetsRoot "textures\item"
$blockTextureRoot = Join-Path $assetsRoot "textures\block"
$languagePath = Join-Path $assetsRoot "lang\en_us.json"
$outputPath = Join-Path $gameRoot "lua\mcgame\generated\sh_generated_items.lua"
$creativeOutputPath = Join-Path $gameRoot "lua\mcgame\generated\sh_generated_creative_tabs.lua"

foreach ( $required in @( $itemsJavaPath, $itemIdsPath, $blockItemIdsPath, $toolMaterialPath, $armorMaterialsPath, $armorTypePath, $creativeTabsPath, $itemDefinitionRoot, $itemTextureRoot, $blockTextureRoot, $languagePath ) ) {
	if ( -not ( Test-Path -LiteralPath $required ) ) { throw "Missing Minecraft source asset: $required" }
}

function ConvertTo-LuaString( [AllowNull()][string] $Value ) {
	if ( [string]::IsNullOrEmpty( $Value ) ) { return "nil" }
	$escaped = $Value.Replace( "\", "\\" ).Replace( '"', '\"' ).Replace( "`r", "\r" ).Replace( "`n", "\n" )
	return '"' + $escaped + '"'
}

function Read-IdentifierMap( [string] $Path, [string] $Pattern ) {
	$map = @{}
	$text = Get-Content -LiteralPath $Path -Raw
	foreach ( $match in [regex]::Matches( $text, $Pattern ) ) {
		$map[$match.Groups[1].Value] = $match.Groups[2].Value
	}
	return $map
}

$itemIds = Read-IdentifierMap $itemIdsPath 'public static final ResourceKey<Item>\s+([A-Z0-9_]+)\s*=\s*(?:create|createSpawnEgg)\("?([a-z0-9_./-]+)"?'
$blockItemIds = @{}
$blockNamesByItemName = @{}
$blockItemIdText = Get-Content -LiteralPath $blockItemIdsPath -Raw
foreach ( $match in [regex]::Matches( $blockItemIdText, 'public static final BlockItemId\s+([A-Z0-9_]+)\s*=\s*BlockItemId\.create\("([a-z0-9_./-]+)"(?:,\s*"([a-z0-9_./-]+)")?\)' ) ) {
	$itemName = if ( $match.Groups[3].Success ) { $match.Groups[3].Value } else { $match.Groups[2].Value }
	$blockItemIds[$match.Groups[1].Value] = $itemName
	$blockNamesByItemName[$itemName] = $match.Groups[2].Value
}
$blockItemNames = @{}
foreach ( $value in $blockItemIds.Values ) { $blockItemNames[$value] = $true }
$creativeSource = Get-Content -LiteralPath $creativeTabsPath -Raw
$creativeColors = New-Object System.Collections.Generic.List[string]
$colorOrderMatch = [regex]::Match( $creativeSource, 'List<DyeColor>\s+gameplayColorOrder\s*=\s*List\.of\((.*?)\);', [System.Text.RegularExpressions.RegexOptions]::Singleline )
if ( $colorOrderMatch.Success ) {
	foreach ( $match in [regex]::Matches( $colorOrderMatch.Groups[1].Value, 'DyeColor\.([A-Z_]+)' ) ) {
		$creativeColors.Add( $match.Groups[1].Value.ToLowerInvariant() )
	}
}
$colorCollectionBases = @{}
foreach ( $colorSourcePath in @( $itemIdsPath, $blockItemIdsPath ) ) {
	$colorSource = Get-Content -LiteralPath $colorSourcePath -Raw
	foreach ( $match in [regex]::Matches( $colorSource, 'ColorCollection<[^;=]+>\s+([A-Z0-9_]+)\s*=\s*createSimpleColored\("([a-z0-9_]+)"\)' ) ) {
		$colorCollectionBases[$match.Groups[1].Value] = $match.Groups[2].Value
		foreach ( $color in $creativeColors ) {
			$name = "${color}_$($match.Groups[2].Value)"
			$blockItemNames[$name] = $true
			$blockNamesByItemName[$name] = $name
		}
	}
}

$toolDurability = @{}
$toolMaterialText = Get-Content -LiteralPath $toolMaterialPath -Raw
$toolPattern = [regex]::new( 'public static final ToolMaterial\s+([A-Z0-9_]+)\s*=\s*new ToolMaterial\((.*?)\);', [System.Text.RegularExpressions.RegexOptions]::Singleline )
foreach ( $match in $toolPattern.Matches( $toolMaterialText ) ) {
	$durability = [regex]::Match( $match.Groups[2].Value, ',\s*(\d+)\s*,' )
	if ( $durability.Success ) { $toolDurability[$match.Groups[1].Value] = [int] $durability.Groups[1].Value }
}

$armorDurabilityMultiplier = @{}
$armorMaterialText = Get-Content -LiteralPath $armorMaterialsPath -Raw
foreach ( $match in [regex]::Matches( $armorMaterialText, 'ArmorMaterial\s+([A-Z0-9_]+)\s*=\s*new ArmorMaterial\(\s*(\d+)' ) ) {
	$armorDurabilityMultiplier[$match.Groups[1].Value] = [int] $match.Groups[2].Value
}
$armorUnitDurability = @{}
$armorTypeText = Get-Content -LiteralPath $armorTypePath -Raw
foreach ( $match in [regex]::Matches( $armorTypeText, '^\s*([A-Z0-9_]+)\([^\r\n]*?,\s*(\d+)\s*,\s*"[a-z_]+"\)', [System.Text.RegularExpressions.RegexOptions]::Multiline ) ) {
	$armorUnitDurability[$match.Groups[1].Value] = [int] $match.Groups[2].Value
}

$source = Get-Content -LiteralPath $itemsJavaPath -Raw
$propertiesByName = @{}
$statementPattern = [regex]::new( 'public static final Item\s+([A-Z0-9_]+)\s*=\s*(.*?);', [System.Text.RegularExpressions.RegexOptions]::Singleline )
foreach ( $match in $statementPattern.Matches( $source ) ) {
	$body = $match.Groups[2].Value
	$idMatch = [regex]::Match( $body, '(?:ItemIds|BlockItemIds)\.([A-Z0-9_]+)' )
	if ( -not $idMatch.Success ) { continue }
	$constant = $idMatch.Groups[1].Value
	$name = if ( $itemIds.ContainsKey( $constant ) ) { $itemIds[$constant] } elseif ( $blockItemIds.ContainsKey( $constant ) ) { $blockItemIds[$constant] } else { $null }
	if ( -not $name ) { continue }

	$maxStack = 64
	$maxDamage = 0
	$stackMatch = [regex]::Match( $body, '\.stacksTo\((\d+)\)' )
	$damageMatch = [regex]::Match( $body, '\.durability\((\d+)\)' )
	if ( $stackMatch.Success ) { $maxStack = [int] $stackMatch.Groups[1].Value }
	if ( $damageMatch.Success ) { $maxDamage = [int] $damageMatch.Groups[1].Value; $maxStack = 1 }
	if ( -not $damageMatch.Success ) {
		$toolMatch = [regex]::Match( $body, 'ToolMaterial\.([A-Z0-9_]+)' )
		if ( $toolMatch.Success -and $toolDurability.ContainsKey( $toolMatch.Groups[1].Value ) ) {
			$maxDamage = $toolDurability[$toolMatch.Groups[1].Value]
			$maxStack = 1
		}
		$armorMatch = [regex]::Match( $body, 'ArmorMaterials\.([A-Z0-9_]+)[\s\S]*?ArmorType\.([A-Z0-9_]+)' )
		if ( $armorMatch.Success -and $armorDurabilityMultiplier.ContainsKey( $armorMatch.Groups[1].Value ) -and $armorUnitDurability.ContainsKey( $armorMatch.Groups[2].Value ) ) {
			$maxDamage = $armorDurabilityMultiplier[$armorMatch.Groups[1].Value] * $armorUnitDurability[$armorMatch.Groups[2].Value]
			$maxStack = 1
		}
	}
	$rarityMatch = [regex]::Match( $body, '\.rarity\(Rarity\.([A-Z]+)\)' )
	$rarity = if ( $rarityMatch.Success ) { $rarityMatch.Groups[1].Value.ToLowerInvariant() } else { "common" }
	$blockMatch = [regex]::Match( $body, 'Blocks\.([A-Z0-9_]+)' )
	$blockName = if ( $blockMatch.Success ) { "minecraft:" + $blockMatch.Groups[1].Value.ToLowerInvariant() } else { $null }
	$propertiesByName[$name] = [pscustomobject]@{
		MaxStack = $maxStack
		MaxDamage = $maxDamage
		Rarity = $rarity
		BlockName = $blockName
	}
}

$languageKeys = @{}
foreach ( $property in ( Get-Content -LiteralPath $languagePath -Raw -Encoding UTF8 | ConvertFrom-Json ).PSObject.Properties ) {
	$languageKeys[$property.Name] = $true
}
# Minecraft names an item by item.minecraft.<id>, a BlockItem usually by its
# block's key. A row without either gets nil and the registry derives
# item.minecraft.<id>, which then shows up as a missing translation.
function Get-ItemTranslationKey( [string] $Name ) {
	foreach ( $key in @( "item.minecraft.$Name", "block.minecraft.$Name" ) ) {
		if ( $languageKeys.ContainsKey( $key ) ) { return $key }
	}
	return $null
}

$singleStackPattern = '(^|_)(sword|shovel|pickaxe|axe|hoe|spear|helmet|chestplate|leggings|boots)$|^(bow|crossbow|trident|mace|shield|elytra|fishing_rod|flint_and_steel|shears|brush|spyglass|wolf_armor|carrot_on_a_stick|warped_fungus_on_a_stick)$|(_minecart|_boat|_chest_boat|_raft|_chest_raft|_shulker_box|_bundle|_harness|_bed|_horse_armor)$'
$stack16Pattern = '(_banner)$'
$blockLayerItemTextures = @{
	# models/item/lever.json is item/generated with minecraft:block/lever as
	# layer0. Copy that exact Java sprite into Source's item material namespace.
	lever = "lever"
}
$rows = New-Object System.Collections.Generic.List[object]
foreach ( $definitionFile in Get-ChildItem -LiteralPath $itemDefinitionRoot -Filter "*.json" | Sort-Object BaseName ) {
	$name = $definitionFile.BaseName
	$properties = $propertiesByName[$name]
	$maxStack = if ( $name -match $singleStackPattern ) { 1 } elseif ( $name -match $stack16Pattern ) { 16 } elseif ( $properties ) { $properties.MaxStack } else { 64 }
	$maxDamage = if ( $properties ) { $properties.MaxDamage } else { 0 }
	$rarity = if ( $properties ) { $properties.Rarity } else { "common" }
	$blockName = if ( $properties -and $properties.BlockName ) { $properties.BlockName } else { $null }
	if ( -not $blockName -and $blockNamesByItemName.ContainsKey( $name ) ) {
		$blockName = "minecraft:$($blockNamesByItemName[$name])"
	}
	if ( $blockName -and -not ( $blockName -eq "minecraft:$name" ) -and -not $blockItemNames.ContainsKey( $name ) ) { $blockName = $null }

	$rawDefinition = Get-Content -LiteralPath $definitionFile.FullName -Raw
	$modelMatch = [regex]::Match( $rawDefinition, '"model"\s*:\s*"(minecraft:[a-z0-9_./-]+)"' )
	$model = if ( $modelMatch.Success ) { $modelMatch.Groups[1].Value } else { $null }
	$exactTexture = Join-Path $itemTextureRoot "$name.png"
	$frameTexture = Join-Path $itemTextureRoot ( "{0}_00.png" -f $name )
	$blockLayerTexture = if ( $blockLayerItemTextures.ContainsKey( $name ) ) {
		Join-Path $blockTextureRoot ( "$($blockLayerItemTextures[$name]).png" )
	} else { $null }
	$texture = if ( Test-Path -LiteralPath $exactTexture ) { "mc/item/$name" } elseif ( Test-Path -LiteralPath $frameTexture ) {
		"mc/item/${name}_00"
	} elseif ( $blockLayerTexture -and ( Test-Path -LiteralPath $blockLayerTexture ) ) { "mc/item/$name" } else { $null }
	$kind = if ( $blockItemNames.ContainsKey( $name ) -or ( $model -and $model.StartsWith( "minecraft:block/" ) ) ) { "block" } else { "item" }

	$rows.Add( [pscustomobject]@{
		Name = "minecraft:$name"
		MaxStack = [Math]::Min( 99, [Math]::Max( 1, $maxStack ) )
		MaxDamage = [Math]::Max( 0, $maxDamage )
		BlockName = $blockName
		Texture = $texture
		TranslationKey = Get-ItemTranslationKey $name
		Rarity = $rarity
		Kind = $kind
		Model = $model
	} )
}

$version = Get-Content -LiteralPath ( Join-Path $minecraftRoot "version.json" ) -Raw | ConvertFrom-Json
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add( "-- Generated by tools/content/generate_items.ps1 from Minecraft $($version.id)." )
$lines.Add( "-- Do not hand edit; regenerate from an extracted Minecraft client." )
$lines.Add( "MC = MC or {}" )
$lines.Add( "MC.GeneratedItemSourceVersion = " + ( ConvertTo-LuaString $version.id ) )
$lines.Add( "-- name, maxStack, maxDamage, block, texture, translationKey, rarity, kind, model" )
$lines.Add( "MC.GeneratedItemDefinitions = {" )
foreach ( $row in $rows ) {
	$lines.Add( ( "`t{{{0},{1},{2},{3},{4},{5},{6},{7},{8}}}," -f
		( ConvertTo-LuaString $row.Name ), $row.MaxStack, $row.MaxDamage,
		( ConvertTo-LuaString $row.BlockName ), ( ConvertTo-LuaString $row.Texture ),
		( ConvertTo-LuaString $row.TranslationKey ), ( ConvertTo-LuaString $row.Rarity ),
		( ConvertTo-LuaString $row.Kind ), ( ConvertTo-LuaString $row.Model ) ) )
}
$lines.Add( "}" )
$lines.Add( "for _, row in ipairs( MC.GeneratedItemDefinitions ) do" )
$lines.Add( "`tlocal registered, err = MC.RegisterItem( {" )
$lines.Add( "`t`tname = row[1], maxStack = row[2], maxDamage = row[3], block = row[4]," )
$lines.Add( "`t`ttexture = row[5], translationKey = row[6], rarity = row[7], kind = row[8], model = row[9]," )
$lines.Add( "`t`tsource = MC.GeneratedItemSourceVersion," )
$lines.Add( "`t} )" )
$lines.Add( "`t" + 'if not registered and err ~= "duplicate_item" then' )
$lines.Add( "`t`t" + 'local message = "[MC] generated item registration failed: " .. tostring( row[1] ) .. " (" .. tostring( err ) .. ")\n"' )
$lines.Add( "`t`tif ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end" )
$lines.Add( "`tend" )
$lines.Add( "end" )
[IO.File]::WriteAllText( $outputPath, ( $lines -join "`n" ) + "`n", [Text.UTF8Encoding]::new( $false ) )

$constantNames = @{}
foreach ( $entry in $itemIds.GetEnumerator() ) { $constantNames[$entry.Key] = $entry.Value }
foreach ( $entry in $blockItemIds.GetEnumerator() ) { $constantNames[$entry.Key] = $entry.Value }
$creativeKeys = @(
	"BUILDING_BLOCKS", "COLORED_BLOCKS", "NATURAL_BLOCKS", "FUNCTIONAL_BLOCKS", "REDSTONE_BLOCKS",
	"HOTBAR", "SEARCH", "TOOLS_AND_UTILITIES", "COMBAT", "FOOD_AND_DRINKS", "INGREDIENTS", "SPAWN_EGGS", "OP_BLOCKS", "INVENTORY"
)
$creativeRows = New-Object System.Collections.Generic.List[object]
foreach ( $key in $creativeKeys ) {
	$startMatch = [regex]::Match( $creativeSource, 'Registry\.register\(\s*registry,\s*' + [regex]::Escape( $key ) + '\s*,', [System.Text.RegularExpressions.RegexOptions]::Singleline )
	if ( -not $startMatch.Success ) { continue }
	$nextIndex = $creativeSource.IndexOf( "Registry.register(", $startMatch.Index + $startMatch.Length )
	if ( $nextIndex -lt 0 ) { $nextIndex = $creativeSource.Length }
	$segment = $creativeSource.Substring( $startMatch.Index, $nextIndex - $startMatch.Index )
	$builder = [regex]::Match( $segment, 'CreativeModeTab\.builder\(CreativeModeTab\.Row\.([A-Z]+),\s*(\d+)\)' )
	$titleMatch = [regex]::Match( $segment, '\.title\(Component\.translatable\("([^"]+)"\)\)' )
	$iconMatch = [regex]::Match( $segment, '\.icon\(\(\)\s*->\s*new ItemStack\((?:Items|Blocks)\.([A-Z0-9_]+)(?:\.([a-z0-9_]+)\(\))?' )
	$items = New-Object System.Collections.Generic.List[string]
	$seenItems = @{}
	foreach ( $accept in [regex]::Matches( $segment, '\.accept\((?:Items|Blocks)\.([A-Z0-9_]+)' ) ) {
		$constant = $accept.Groups[1].Value
		$name = if ( $constantNames.ContainsKey( $constant ) ) { $constantNames[$constant] } else { $constant.ToLowerInvariant() }
		if ( -not $seenItems.ContainsKey( $name ) ) { $seenItems[$name] = $true; $items.Add( "minecraft:$name" ) }
	}
	$colorCollections = New-Object System.Collections.Generic.List[string]
	foreach ( $colored in [regex]::Matches( $segment, 'registerColoredItems\([^;]+?Items\.([A-Z0-9_]+)\)' ) ) {
		$colorCollections.Add( $colored.Groups[1].Value )
	}
	foreach ( $colored in [regex]::Matches( $segment, 'Items\.([A-Z0-9_]+)\.forEach\(' ) ) {
		if ( $colorCollectionBases.ContainsKey( $colored.Groups[1].Value ) ) { $colorCollections.Add( $colored.Groups[1].Value ) }
	}
	foreach ( $collection in $colorCollections ) {
		if ( -not $colorCollectionBases.ContainsKey( $collection ) ) { continue }
		$baseName = $colorCollectionBases[$collection]
		foreach ( $color in $creativeColors ) {
			$name = "${color}_${baseName}"
			if ( -not $seenItems.ContainsKey( $name ) ) { $seenItems[$name] = $true; $items.Add( "minecraft:$name" ) }
		}
	}
	if ( $key -eq "SEARCH" ) {
		foreach ( $row in $rows ) {
			$name = $row.Name
			if ( $name -ne "minecraft:air" -and -not $seenItems.ContainsKey( $name ) ) { $seenItems[$name] = $true; $items.Add( $name ) }
		}
	}
	if ( $key -eq "HOTBAR" -or $key -eq "INVENTORY" ) {
		$items.Clear()
		$seenItems = @{}
	}
	$iconConstant = if ( $iconMatch.Success ) { $iconMatch.Groups[1].Value } else { "STONE" }
	$iconName = if ( $constantNames.ContainsKey( $iconConstant ) ) { $constantNames[$iconConstant] } else { $iconConstant.ToLowerInvariant() }
	$iconColor = if ( $iconMatch.Success ) { $iconMatch.Groups[2].Value } else { "" }
	if ( $iconColor -and $colorCollectionBases.ContainsKey( $iconConstant ) ) {
		$iconName = "${iconColor}_$($colorCollectionBases[$iconConstant])"
	}
	$titleKey = if ( $titleMatch.Success ) { $titleMatch.Groups[1].Value } else { "itemGroup." + $key.ToLowerInvariant() }
	$creativeRows.Add( [pscustomobject]@{
		Key = $key.ToLowerInvariant()
		Row = if ( $builder.Success ) { $builder.Groups[1].Value.ToLowerInvariant() } else { "top" }
		Column = if ( $builder.Success ) { [int] $builder.Groups[2].Value } else { 0 }
		TitleKey = $titleKey
		Icon = "minecraft:$iconName"
		Items = $items
	} )
}

$creativeLines = New-Object System.Collections.Generic.List[string]
$creativeLines.Add( "-- Generated by tools/content/generate_items.ps1 from CreativeModeTabs.java ($($version.id))." )
$creativeLines.Add( "MC = MC or {}" )
$creativeLines.Add( "MC.GeneratedCreativeTabs = {" )
foreach ( $tab in $creativeRows ) {
	$itemText = ( $tab.Items | ForEach-Object { ConvertTo-LuaString $_ } ) -join ","
	$creativeLines.Add( ( "`t{{key={0},row={1},column={2},titleKey={3},icon={4},items={{{5}}}}}," -f
		( ConvertTo-LuaString $tab.Key ), ( ConvertTo-LuaString $tab.Row ), $tab.Column,
		( ConvertTo-LuaString $tab.TitleKey ), ( ConvertTo-LuaString $tab.Icon ), $itemText ) )
}
$creativeLines.Add( "}" )
[IO.File]::WriteAllText( $creativeOutputPath, ( $creativeLines -join "`n" ) + "`n", [Text.UTF8Encoding]::new( $false ) )
if ( $SkipMaterials ) {
	Write-Host "Generated $($rows.Count) item definitions and $($creativeRows.Count) creative tabs (materials skipped)."
	return
}

$materialItemRoot = Join-Path $gameRoot "materials\mc\item"
$materialGuiRoot = Join-Path $gameRoot "materials\mc\gui"
$materialContainerRoot = Join-Path $materialGuiRoot "container"
$materialHudRoot = Join-Path $materialGuiRoot "hud"
$materialSpriteRoot = Join-Path $materialGuiRoot "sprites\container"
$materialRecipeBookRoot = Join-Path $materialGuiRoot "sprites\recipe_book"
$materialCreativeRoot = Join-Path $materialContainerRoot "creative_inventory"
$materialCreativeSpriteRoot = Join-Path $materialSpriteRoot "creative_inventory"
New-Item -ItemType Directory -Force -Path $materialItemRoot, $materialContainerRoot, $materialHudRoot, $materialSpriteRoot, $materialCreativeRoot, $materialCreativeSpriteRoot, $materialRecipeBookRoot | Out-Null
Copy-Item -Path ( Join-Path $itemTextureRoot "*.png" ) -Destination $materialItemRoot -Force
foreach ( $entry in $blockLayerItemTextures.GetEnumerator() ) {
	Copy-Item -LiteralPath ( Join-Path $blockTextureRoot ( "$($entry.Value).png" ) ) -Destination ( Join-Path $materialItemRoot ( "$($entry.Key).png" ) ) -Force
}
Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\container\inventory.png" ) -Destination $materialContainerRoot -Force
Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\container\generic_54.png" ) -Destination $materialContainerRoot -Force
Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\container\crafting_table.png" ) -Destination $materialContainerRoot -Force
Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\recipe_book.png" ) -Destination $materialGuiRoot -Force
Copy-Item -Path ( Join-Path $assetsRoot "textures\gui\container\creative_inventory\*.png" ) -Destination $materialCreativeRoot -Force
foreach ( $name in @( "hotbar.png", "hotbar_selection.png", "hotbar_offhand_left.png", "hotbar_offhand_right.png" ) ) {
	Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\sprites\hud\$name" ) -Destination $materialHudRoot -Force
}
foreach ( $name in @( "slot.png", "slot_highlight_back.png", "slot_highlight_front.png" ) ) {
	Copy-Item -LiteralPath ( Join-Path $assetsRoot "textures\gui\sprites\container\$name" ) -Destination $materialSpriteRoot -Force
}
Copy-Item -Path ( Join-Path $assetsRoot "textures\gui\sprites\container\creative_inventory\*.png" ) -Destination $materialCreativeSpriteRoot -Force
Copy-Item -Path ( Join-Path $assetsRoot "textures\gui\sprites\recipe_book\*.png" ) -Destination $materialRecipeBookRoot -Force

Write-Host ( "Generated {0} item definitions, {1} creative tabs and copied {2} item textures." -f $rows.Count, $creativeRows.Count, ( Get-ChildItem -LiteralPath $materialItemRoot -Filter "*.png" ).Count )
