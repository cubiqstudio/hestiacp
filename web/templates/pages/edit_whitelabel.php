<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a href="/edit/server/" class="button button-secondary" id="btn-back">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml( _("Back")) ?>
			</a>
		</div>
		<div class="toolbar-buttons">
			<button type="submit" class="button" form="main-form">
				<i class="fas fa-floppy-disk icon-purple"></i><?= tohtml( _("Save")) ?>
			</button>
		</div>
	</div>
</div>
<!-- End toolbar -->

<!-- Begin form -->
<div class="container">
	<form
		x-data="{
			hide_docs: '<?= tohtml($v_hide_docs ?? "yes") ?>',
		}"
		id="main-form"
		name="v_configure_server"
		method="post"
	>
		<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
		<input type="hidden" name="save" value="save">

		<div class="form-container">
			<h1 class="u-mb20">
				<?= tohtml( _("White Label Options")) ?>
			</h1>
			<?php show_alert_message($_SESSION); ?>

			<!-- Basic options section -->
			<details class="box-collapse u-mb10">
				<summary class="box-collapse-header">
					<i class="fas fa-gear u-mr15"></i>
					<?= tohtml( _("General")) ?>
				</summary>
				<div class="box-collapse-content">
					<div class="u-mb10">
						<label for="v_app_name" class="form-label">
							<?= tohtml( _("Application Name")) ?>
						</label>
						<input
							type="text"
							class="form-control"
							name="v_app_name"
							id="v_app_name"
							value="<?= tohtml(trim($v_app_name, "'")) ?>"
						>
					</div>
					<div class="u-mb10">
						<label for="v_title" class="form-label">
							<?= tohtml( _("Title")) ?><span class="optional">(<?= tohtml( _("Supported variables")) ?>: {{appname}}, {{hostname}}, {{ip}} and {{page}} )</span>
						</label>
						<input
							type="text"
							class="form-control"
							name="v_title"
							id="v_title"
							value="<?= tohtml(trim($v_title, "'")) ?>"
						>
					</div>
					<div class="u-mb10">
						<label for="v_from_name" class="form-label">
							<?= tohtml( _("Sender Name")) ?><span class="optional">(<?= tohtml( _("Default")) ?>: <?= tohtml(trim($v_app_name, "'")) ?>)</span>
						</label>
						<input
							type="text"
							class="form-control"
							name="v_from_name"
							id="v_from_name"
							value="<?= tohtml(trim($v_from_name, "'")) ?>"
						>
					</div>
					<div class="u-mb10">
						<label for="v_from_email" class="form-label">
							<?= tohtml( _("Sender Email Address")) ?><span class="optional">(<?= tohtml( _("Default")) ?>: <?= tohtml(sprintf("noreply@%s", trim(get_hostname(), "'"))) ?>)</span>
						</label>
						<input
							type="email"
							class="form-control"
							name="v_from_email"
							id="v_from_email"
							value="<?= tohtml(trim($v_from_email, "'")) ?>"
						>
					</div>
					<div class="u-mb10">
						<label for="v_subject_email" class="form-label">
							<?= tohtml( _("Email Subject")) ?><span class="optional">(<?= tohtml( _("Supported variables")) ?>: {{appname}}, {{hostname}}, {{subject}} )</span>
						</label>
						<input
							type="text"
							class="form-control"
							name="v_subject_email"
							id="v_subject_email"
							value="<?= tohtml(trim($v_subject_email, "'")) ?>"
						>
					</div>
					<div class="u-mb10">
						<label for="v_hide_docs" class="form-label">
							<?= tohtml( _("Hide link to Documentation")) ?>
						</label>
						<select x-model="hide_docs" class="form-select" name="v_hide_docs" id="v_hide_docs">
							<option value="yes"><?= tohtml( _("Yes")) ?></option>
							<option value="no"><?= tohtml( _("No")) ?></option>
						</select>
					</div>
				</div>
			</details>
		</div>
	</form>
</div>
<!-- End form -->
