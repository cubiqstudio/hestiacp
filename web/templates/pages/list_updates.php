<?php
	// Upstream update channels are switched off unless UPSTREAM_UPDATES is 'yes' in hestia.conf
	$upstream_updates = ($_SESSION["UPSTREAM_UPDATES"] ?? "no") === "yes";
	// Own package source (v-update-sys-vylaris), on when VYLARIS_UPDATES is 'yes' in hestia.conf
	$own_updates = ($_SESSION["VYLARIS_UPDATES"] ?? "no") === "yes";
	$app_name = $_SESSION["APP_NAME"] ?? "VylarisSpace";
	$own_installed = $data["hestia"]["VERSION"] ?? "";
	$own_candidate = $data["hestia"]["CANDIDATE"] ?? "";
	$show_status = $upstream_updates || $own_updates;
?>
<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a class="button button-secondary button-back js-button-back" href="/list/server/">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml( _("Back")) ?>
			</a>
			<?php if ($own_updates) { ?>
				<a class="button button-secondary" href="/update/vylaris/?<?= tohtml(http_build_query(["action" => "check", "token" => $_SESSION["token"]])) ?>">
					<i class="fas fa-arrow-rotate-right icon-blue"></i><?= tohtml( _("Check for Updates")) ?>
				</a>
				<?php if ($own_candidate !== "") { ?>
					<a class="button button-secondary" href="/update/vylaris/?<?= tohtml(http_build_query(["action" => "install", "token" => $_SESSION["token"]])) ?>">
						<i class="fas fa-download icon-green"></i><?= tohtml( _("Update Now")) ?>
					</a>
				<?php } ?>
			<?php } ?>
			<?php if ($show_status) { ?>
				<?php
					$auto_enabled = $own_updates
						? ($data["hestia"]["AUTOUPDATE"] ?? "no") === "yes"
						: $autoupdate == 'Enabled';
					if ($auto_enabled) {
						$btn_url = '/delete/cron/autoupdate/?token='.$_SESSION['token'].'';
						$btn_icon = 'fa-toggle-on icon-green';
						$btn_label = _('Disable Automatic Updates');
					} else {
						$btn_url = '/add/cron/autoupdate/?token='.$_SESSION['token'].'';
						$btn_icon = 'fa-toggle-off icon-red';
						$btn_label = _('Enable Automatic Updates');
					}
				?>
				<a class="button button-secondary" href="<?= tohtml($btn_url) ?>">
					<i class="fas <?= tohtml($btn_icon) ?>"></i><?= tohtml($btn_label) ?>
				</a>
			<?php } ?>
		</div>
	</div>
</div>
<!-- End toolbar -->

<div class="container">

	<h1 class="u-text-center u-hide-desktop u-mt20 u-pr30 u-mb20 u-pl30"><?= tohtml( _("Updates")) ?></h1>

	<?php if (!empty($_SESSION["ok_msg"])) { ?>
		<div class="alert alert-success u-mt20 u-mb20" role="alert">
			<i class="fas fa-check"></i>
			<p><?= tohtml($_SESSION["ok_msg"]) ?></p>
		</div>
	<?php } ?>

	<?php if ($own_updates && $own_candidate !== "") { ?>
		<div class="alert alert-warning u-mt20 u-mb20" role="alert">
			<i class="fas fa-triangle-exclamation"></i>
			<p><?= tohtml( sprintf(_("A new version of %s is available: %s is installed, %s can be installed from the own package source."), $app_name, $own_installed, $own_candidate)) ?></p>
		</div>
	<?php } elseif ($own_updates) { ?>
		<div class="alert alert-success u-mt20 u-mb20" role="alert">
			<i class="fas fa-check"></i>
			<p><?= tohtml( sprintf(_("%s %s is up to date. Use Check for Updates to refresh the data from the own package source."), $app_name, $own_installed)) ?></p>
		</div>
	<?php } ?>

	<?php if (!$show_status) { ?>
		<div class="alert alert-info u-mt20 u-mb20" role="alert">
			<i class="fas fa-info"></i>
			<p><?= tohtml( _("Upstream updates are disabled. This server is updated through its own package source. The installed package versions are listed below.")) ?></p>
		</div>
	<?php } ?>

	<div class="units-table js-units-container">
		<div class="units-table-header">
			<div class="units-table-cell"><?= tohtml( _("Package Name")) ?></div>
			<div class="units-table-cell"><?= tohtml( _("Description")) ?></div>
			<div class="units-table-cell u-text-center"><?= tohtml( _("Version")) ?></div>
			<?php if ($own_updates) { ?>
				<div class="units-table-cell u-text-center"><?= tohtml( _("Available")) ?></div>
			<?php } ?>
			<?php if ($show_status) { ?>
				<div class="units-table-cell u-text-center"><?= tohtml( _("Status")) ?></div>
			<?php } ?>
		</div>

		<!-- Begin update list item loop -->
		<?php
			foreach ($data as $key => $value) {
				++$i;

				// The own package source only tracks the panel package (hestia)
				$tracked = $upstream_updates || ($own_updates && $key == 'hestia');

				if (!$tracked || $data[$key]['UPDATED'] == 'yes') {
					$status = 'active';
					$upd_status = 'updated';
				} else {
					$status = 'suspended';
					$upd_status = 'outdated';
				}
			?>
			<div class="units-table-row <?php if ($status == 'suspended') echo 'disabled units-table-row-outdated'; ?> js-unit">
				<div class="units-table-cell units-table-heading-cell u-text-bold">
					<span class="u-hide-desktop"><?= tohtml( _("Package Names")) ?>:</span>
					<?= tohtml($key) ?>
				</div>
				<div class="units-table-cell">
					<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Description")) ?>:</span>
					<?= tohtml( _($data[$key]["DESCR"])) ?>
				</div>
				<div class="units-table-cell u-text-center-desktop">
					<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Version")) ?>:</span>
					<?= tohtml($data[$key]["VERSION"]) ?> (<?= tohtml($data[$key]["ARCH"]) ?>)
				</div>
				<?php if ($own_updates) { ?>
					<div class="units-table-cell u-text-center-desktop">
						<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Available")) ?>:</span>
						<?= tohtml(($data[$key]["CANDIDATE"] ?? "") !== "" ? $data[$key]["CANDIDATE"] : "-") ?>
					</div>
				<?php } ?>
				<?php if ($show_status) { ?>
					<div class="units-table-cell u-text-center-desktop">
						<span class="u-hide-desktop u-text-bold"><?= tohtml( _("Status")) ?>:</span>
						<?php if (!$tracked): ?>
							-
						<?php elseif ($data[$key]['UPDATED'] == 'no'): ?>
							<i class="fas fa-triangle-exclamation icon-orange" title="<?= tohtml( _("Update available")) ?>"></i>
						<?php elseif ($data[$key]['UPDATED'] == 'yes'): ?>
							<i class="fas fa-circle-check icon-green" title="<?= tohtml( _("Package up-to-date")) ?>"></i>
						<?php endif; ?>
					</div>
				<?php } ?>
			</div>
		<?php } ?>
	</div>

</div>
