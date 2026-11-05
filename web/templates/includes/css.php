<?= brand_favicon_links() ?>
<link rel="stylesheet" href="/css/themes/default.min.css?<?= JS_LATEST_UPDATE ?>">

<?php
$selected_theme = resolve_theme(
	!empty($_SESSION["userTheme"]) ? $_SESSION["userTheme"] : $_SESSION["THEME"] ?? "",
);
// Load the selected theme (legacy theme names are mapped to the Vylaris themes)
if ($selected_theme !== "default") {
	// Load shipped themes (minified, updated/overwritten with updates) - ($HESTIA/web/css/themes/*.min.css)
	$non_default_theme_path = $_SERVER["HESTIA"] . "/web/css/themes/" . $selected_theme . ".min.css";
	if (file_exists($non_default_theme_path)) {
		echo '<link rel="stylesheet" href="/css/themes/' . $selected_theme . ".min.css?" . JS_LATEST_UPDATE . '">';
	}
	// Load custom theme files ($HESTIA/web/css/themes/custom/*.css)
	else {
		$custom_theme_path = $_SERVER["HESTIA"] . "/web/css/themes/custom/" . $selected_theme . ".min.css";
		if (file_exists($custom_theme_path)) {
			echo '<link rel="stylesheet" href="/css/themes/custom/' . $selected_theme . ".min.css?" . JS_LATEST_UPDATE . '">';
		} else {
			echo '<link rel="stylesheet" href="/css/themes/custom/' . $selected_theme . ".css?" . JS_LATEST_UPDATE . '">';
		}
	}
}

?>
