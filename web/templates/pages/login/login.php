<div class="login">
	<a href="/" class="u-block u-mb40">
		<img class="logo-mark logo-mark--login logo-mark--on-light" src="/images/vylaris/logo-mark-on-light.svg" alt="<?= tohtml($_SESSION["APP_NAME"]) ?>" width="108" height="72">
		<img class="logo-mark logo-mark--login logo-mark--on-dark" src="/images/vylaris/logo-mark-on-dark.svg" alt="<?= tohtml($_SESSION["APP_NAME"]) ?>" width="108" height="72">
	</a>
	<form id="login-form" method="post" action="/login/">
		<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
		<h1 class="login-title">
			<?= tohtml(sprintf(_("Welcome to %s"), $_SESSION["APP_NAME"])) ?>
		</h1>
		<?php if (!empty($error)) { ?>
			<p class="error"><?= tohtml($error) ?></p>
		<?php } ?>
		<div class="u-mb20">
			<label for="username" class="form-label"><?= tohtml( _("Username")) ?></label>
			<input type="text" class="form-control" name="user" id="username" autocomplete="username" required autofocus>
		</div>
		<button type="submit" class="button">
			<i class="fas fa-right-to-bracket"></i><?= tohtml( _("Next")) ?>
		</button>
	</form>
</div>
