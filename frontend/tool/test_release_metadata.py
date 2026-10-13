import unittest

from release_metadata import release_metadata


class ReleaseMetadataTest(unittest.TestCase):
    def test_stable_version(self):
        self.assertEqual(
            release_metadata("v1.2.3"),
            {
                "valid": "true",
                "version": "1.2.3",
                "build_name": "1.2.3",
                "prerelease": "false",
                "package_version": "1.2.3",
            },
        )

    def test_prerelease_and_metadata_preserved_in_filename(self):
        result = release_metadata("v1.2.3-rc.1+build.007")
        self.assertEqual(result["version"], "1.2.3-rc.1+build.007")
        self.assertEqual(result["build_name"], "1.2.3")
        self.assertEqual(result["prerelease"], "true")
        self.assertEqual(result["package_version"], "1.2.3-rc.1")

    def test_metadata_does_not_make_a_prerelease(self):
        result = release_metadata("v0.0.0+001")
        self.assertEqual(result["prerelease"], "false")
        self.assertEqual(result["package_version"], "0.0.0")

    def test_valid_semver_identifiers(self):
        for tag in ("v0.0.0-0", "v1.2.3-01a", "v1.2.3-x-y-z.--", "v1.2.3+01"):
            with self.subTest(tag=tag):
                self.assertEqual(release_metadata(tag)["valid"], "true")

    def test_invalid_tags_skip_all_builds(self):
        for tag in (
            "1.2.3", "v1", "v1.2", "v01.2.3", "v1.02.3", "v1.2.03",
            "v1.2.3-01", "v1.2.3-rc.01", "v1.2.3-", "v1.2.3+",
            "v1.2.3-rc..1", "v1.2.3+foo..bar", "v1.2.3\n",
            "v1.2.3/evil", "v1.2.3-$(echo bad)", "v1.2.3-α",
        ):
            with self.subTest(tag=tag):
                self.assertEqual(release_metadata(tag), {"valid": "false"})


if __name__ == "__main__":
    unittest.main()
