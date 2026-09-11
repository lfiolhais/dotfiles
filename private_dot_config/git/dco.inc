# Only the repositories the includeIf in ~/.gitconfig matched read this file.
# core.hooksPath replaces .git/hooks rather than adding to it, so a matched
# repository stops running hooks of its own. A matched repository that sets
# core.hooksPath in .git/config keeps that one and gets no sign-off, because
# local configuration wins over an include in ~/.gitconfig.
[core]
	hooksPath = ~/.config/git/hooks-dco
