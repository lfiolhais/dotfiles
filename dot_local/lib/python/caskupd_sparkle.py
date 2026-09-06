"""Sparkle's two preference keys, and reading and writing them.

Sparkle is the update framework most Mac apps embed, and it takes its automatic
checking settings from the app's *own* user-defaults domain, where they take
precedence over the same keys in the bundle's ``Info.plist``. That is the whole
lever this library pulls: two values in a preference domain, nothing touched
inside the app bundle, and no code signature disturbed.

It is best-effort by nature. An app that sets ``automaticallyChecksForUpdates``
in code on every launch will undo this, and nothing here pretends otherwise --
:meth:`Sparkle.silenced` reads the state back rather than assuming the write
stuck.
"""

from __future__ import annotations

from chezpkg_run import maybe, run

# Whether Sparkle schedules its background check at all. Unset, Sparkle asks the
# user for permission on first launch; false is what stops both.
CHECKS = "SUEnableAutomaticChecks"
# Whether an update Sparkle found may install itself silently.
INSTALLS = "SUAutomaticallyUpdate"
KEYS = (CHECKS, INSTALLS)
# What `defaults read` prints for a boolean that is off.
OFF = "0"


class Sparkle:
    """The Sparkle preference keys of one app, as `defaults` sees them."""

    @staticmethod
    def state(bundle_id: str) -> dict[str, str]:
        """Read both keys out of an app's preference domain.

        Args:
            bundle_id: The app's bundle identifier.

        Returns:
            Each key mapped to what ``defaults read`` printed, empty when the
            key is unset.

        """
        return {key: maybe("defaults", "read", bundle_id, key) for key in KEYS}

    @classmethod
    def silenced(cls, bundle_id: str) -> bool:
        """Report whether an app is already silent.

        Args:
            bundle_id: The app's bundle identifier.

        Returns:
            True if both keys read back as off.

        """
        return all(value == OFF for value in cls.state(bundle_id).values())

    @staticmethod
    def disable(bundle_id: str) -> None:
        """Stop an app checking for, and installing, its own updates.

        A failure from ``defaults`` propagates as a ``PackagesError``, which is
        the right outcome: an app that cannot be written to has not been
        silenced, and saying so beats reporting a sweep that did not happen.

        Args:
            bundle_id: The app's bundle identifier.

        """
        for key in KEYS:
            run("defaults", "write", bundle_id, key, "-bool", "false")

    @staticmethod
    def restore(bundle_id: str) -> None:
        """Put an app back the way it was found.

        The keys are deleted rather than set true: unset is the real original
        state, and it is what lets the bundle's own ``Info.plist`` decide again.

        Args:
            bundle_id: The app's bundle identifier.

        """
        for key in KEYS:
            maybe("defaults", "delete", bundle_id, key)
