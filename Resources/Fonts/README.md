# Bundled fonts

TypesetKit sets type with these fonts (formats §3, quality §3). They are copied unmodified from CTAN and ship with their
licence texts in each folder. The app copies this folder to `Contents/Resources/Fonts`; `FontLibrary.bundled()` finds
it there, or here when running from a SwiftPM build.

| Folder | Fonts | Version | Licence | Source |
|---|---|---|---|---|
| `LatinModern/` | Latin Modern Roman 5–17 (regular, bold, italic, slanted, caps), Sans 8–17, Mono 8–12: the optical sizes LaTeX's `lmodern` uses | 2.004 | GUST Font License (LPPL 1.3c with a name-change request), `GUST-FONT-LICENSE.txt` | https://ctan.org/pkg/lm |
| `LatinModernMath/` | Latin Modern Math (OpenType MATH table) | 1.959 | GUST Font License, `GUST-FONT-LICENSE.txt` | https://ctan.org/pkg/lm-math |
| `CMU/` | CMU Serif, Sans, Typewriter (Computer Modern Unicode: Greek and Cyrillic) | 0.7.0 | SIL Open Font License 1.1, `OFL.txt` | https://ctan.org/pkg/cm-unicode |
| `STIXTwo/` | STIX Two Math (symbols Latin Modern Math lacks) | 2.12 | SIL Open Font License 1.1, `OFL.txt` | https://ctan.org/pkg/stix2-otf |
| `Carlito/` | Carlito (metric-compatible with Calibri) | 1.103 | SIL Open Font License 1.1, `OFL.txt` | https://ctan.org/pkg/carlito |
| `Caladea/` | Caladea (metric-compatible with Cambria) | 1.002 | Apache License 2.0, `LICENSE-2.0.txt` (as published in Google's crosextrafonts) | https://ctan.org/pkg/caladea |

All are on the licence allow-list of formats §2 (the SIL Open Font License and the GUST Font License for fonts;
Apache-2.0). The fonts are not modified, so the GUST licence's request to rename modified files does not apply.

## SHA-256

```
74eda4fc5ffba0d8dc4aa76d41499f5ab76168d9ed6141c6417064c6244db9b6  Caladea/Caladea-Bold.ttf
f47a35ad6cd0efa9914d93f9d03c93e30c55da43674bccfabac73b3c0d522c01  Caladea/Caladea-BoldItalic.ttf
9c968bf60ba1e851cdfea77c71e3540c57792f77482dd241acc29d1425569c4e  Caladea/Caladea-Italic.ttf
d2f6cad33f191e65b68bd74e6d4f7708080a41b32db635866109df3090265d91  Caladea/Caladea-Regular.ttf
0f62ab34ad5d079a0a28fac01bcf7c7a724a4db4d6cb99cab9cabff382fbb80f  Carlito/Carlito-Bold.ttf
380764b6898d7b73ceae6384b2958b196d2a0428962ef3adf138d27947228666  Carlito/Carlito-BoldItalic.ttf
718a0663864d37a4868220a19b9668a5fe10a46197f6df367b4c2c30c04c026c  Carlito/Carlito-Italic.ttf
b4ff23ba370cc95a3c349336b73f9c28514a1371210f89832efc85c4b1ea7131  Carlito/Carlito-Regular.ttf
690cc3c1511a98e79f5bde8a58868405160da1b7d99f3482324c6a915b496b02  CMU/cmunbi.otf
e956d496776533b0ca1b6e1acaeac896b81b81b908667cbf49840048ed16bd0c  CMU/cmunbx.otf
5089693f81ed5b83435be7167bf2f93c2608ce92fb3a7e13f6be238a733c38f2  CMU/cmunrm.otf
73dfa3be33c4a93abe44753f2d622b1eade86a43eb5a76331095e928b329c34f  CMU/cmunsi.otf
a0e41b8611156eed280c3a730ddcf03c35090fb03efc9413bbe2b1e2915de95b  CMU/cmunss.otf
5d3a5b51898be3279b28734ac135dc89f4971dc7be1215981eff3fa9f66300da  CMU/cmunsx.otf
fc38ce9ea06e49bda118a8be9f053791d043a547c248ae30c9e4fad956de3267  CMU/cmunti.otf
f4302554e94621459f33526dca714e7f9d537128b37556741568ae7115b252b5  CMU/cmuntt.otf
14e6328a5383d2b927c47051093ce0aff60deea07e6df71b8b99ee8d9c2ff8f2  LatinModern/lmmono10-italic.otf
22deb6d3be3ffcb40b33f0e010afb256c677d97c2a2bdee1f5740cdc97751558  LatinModern/lmmono10-regular.otf
b826e490fa671f254840abe88afea0975b606f57fb4a8b93f53787c26d8ac319  LatinModern/lmmono12-regular.otf
17319490d20f24e192bd7e7999484b95111a4654ac2620e7aa215591142ae997  LatinModern/lmmono8-regular.otf
cdd53c7dc01a1d25f21eaf7cae44bfb8a9665e4cbd60e5f8da14287aca819bb9  LatinModern/lmmono9-regular.otf
2f4ae1bd30d4203a1c74c61d61dddbd5e2c2d5a7001d456b1b98e08b7c47ffb9  LatinModern/lmmonolt10-bold.otf
a739b6deaafe0b9e8ae1eec9db1f425c52e1f6f483ca8e07e359bdd118310bba  LatinModern/lmmonolt10-boldoblique.otf
4b4a3e600db7f6ec434f8b48b31f22e12faced90e1681c93eeba5e23a6e55fde  LatinModern/lmmonoslant10-regular.otf
102fe06c430a8b681b2bf6876b7cd967ae4d47b4b6b41d915eb7913b726d9fb1  LatinModern/lmroman10-bold.otf
c37a28eed7a6e03f792b98b5e5f637b2fcda378bb4855f99284f1a88fe35f124  LatinModern/lmroman10-bolditalic.otf
c1fce25075567bb8dbf2151658c3b442690041db17a2d49fc9e55905ea5b7169  LatinModern/lmroman10-italic.otf
1aa18cfefa58132c52ce5de70db1fd1154201c19cd2b2cdaffba4906a33e6852  LatinModern/lmroman10-regular.otf
28c8782ac2b6486958b5dc7610ada7800c53546ff7f36bc65909a876e1cd338e  LatinModern/lmroman12-bold.otf
ada6b3f451238784e5a5ea75d43efa1eb4329cd75ce65bf047ed2f31b7b5e2f3  LatinModern/lmroman12-italic.otf
e6be218ae83e61aa8a29990d3cdc401c678c1962188cb9a4a8b6359e4f5e5870  LatinModern/lmroman12-regular.otf
ed048c80fb4b67663b80899b89fe5fba17d7442e1286d61fd08fe5689c6b7c3c  LatinModern/lmroman17-regular.otf
6326fb955d07bedcc8f73684e6b6bfa76706d38f3a85bd89c0659504ace366a1  LatinModern/lmroman5-bold.otf
954bd9c376597c7043e7b616430163e0158155edf7434fd70082cf8460c08533  LatinModern/lmroman5-regular.otf
f1ebd52916182bfc2e3f9d4b5ba847ad6acc6c7761354c0dc052fb01ec14f73c  LatinModern/lmroman6-bold.otf
501396c437f76c260b8724265b8495f318a640ee5a4674852ecbb20daf256696  LatinModern/lmroman6-regular.otf
063ea9e378b4fca4fd59771cf522faa21eb7c8516c89464745c79725b384fb9a  LatinModern/lmroman7-bold.otf
19d20f2bb00fbffe5d3d66e9b6a54f0108289068029e9d88649d981d53613ddf  LatinModern/lmroman7-italic.otf
48c4b46ab255eec96588fb992fba1ed6102e53d051da480738a61cc6cdb328c3  LatinModern/lmroman7-regular.otf
04d4f633c3da31a169f4c54a7fe8c7e63925b39d030381f8d3eab955f16be7b2  LatinModern/lmroman8-bold.otf
fb0536b5c3eee5b5622cd827ceb410e6514e36512ebdc51d2cf98a96c06d44e8  LatinModern/lmroman8-italic.otf
f73015c3827596586faa380c398501caf9b5bcbb6f40b46af6a51277ca97c9fc  LatinModern/lmroman8-regular.otf
f72feac9ea12eb858d8093d6c0ee710a6c25f59b61278c88ec41c0a680838415  LatinModern/lmroman9-bold.otf
2106cffcdc9f9cb411d7c3441e34d77a168b998a58b40e727ab5b815437d1975  LatinModern/lmroman9-italic.otf
8ab7b017fc67ea0e30cbf9e7ebd940010442ea67b40cf65f87d73f3ca11b0e6f  LatinModern/lmroman9-regular.otf
603e6bb88c206f3252d2ca1a061d0faf252dd6c87501f2efa32ce2f70793b1ad  LatinModern/lmromancaps10-oblique.otf
1ab40332a969892c7ed6cb010193b5276ccef1da6798bcbd1a465fee23d29334  LatinModern/lmromancaps10-regular.otf
5f6689646a5e88b402d2e60085c813fca3a4d60707b0383c65cb023107a8bddc  LatinModern/lmromanslant10-bold.otf
056ad4d08d2eb58d6b7fd0ac5de3f1fb799f2bb0c16b66c7e6b5bc5b6aef6481  LatinModern/lmromanslant10-regular.otf
25f2ecfb860f2e45e6ebe69d11bc6305f5bfbef8f13476638ba291f47d1f130c  LatinModern/lmromanslant12-regular.otf
4f30eda1d4674a1f4eea513b3baf85e3ba3fb17b2e4cf09bf627aee91dc0a4cc  LatinModern/lmromanslant17-regular.otf
a88ecd1a6b4d5aa1c9d537b98d0de8e19d63b292918fabf0cc36158ed770ca63  LatinModern/lmromanslant8-regular.otf
7441aee0c9dfbca16118fc7fe339c2e6c79ecc966a51ac1f76860351b6a8f02e  LatinModern/lmromanslant9-regular.otf
a597b710326c1a8a2c7238d808e5d38711638a72a32383478db4829d63afd687  LatinModern/lmsans10-bold.otf
e45673d84754a94f2f053bd4c15950b4b320144fbb622c630a26fd7b68cfabc5  LatinModern/lmsans10-boldoblique.otf
1b38b36efc21f9d3f34edf6a13f9d71f59c41f824e790f5d3ee5ba5b4936f377  LatinModern/lmsans10-oblique.otf
d431b786b9b603662718e79cfe9b441f47a8b0b3e854dde89d5acb3ed7cfd682  LatinModern/lmsans10-regular.otf
1f138e6203f7092f9a01f6193ed97d971b5045b99969f3a62c7e43a7faabc1c0  LatinModern/lmsans12-oblique.otf
f87ebdea035a96e8787e2c663cfcc78ce73205d37800eafe7948278e2cc7666a  LatinModern/lmsans12-regular.otf
0f6a4450c5fc9afd3650f24ad9003684fff3252691bbf2a33be94b383db8a77c  LatinModern/lmsans17-oblique.otf
f6c395a436e4fa7e88bbf1445e64b9c78ce4effba3668b13cc433077fc71a984  LatinModern/lmsans17-regular.otf
7f4227513bfd47b7077bedd125caa4c0a223a2cdad17a1470145cdea83353c88  LatinModern/lmsans8-oblique.otf
04f0d25ca474494cb707e752170f6c22cdcb8ae2b5fb80872143e18d5cc463f8  LatinModern/lmsans8-regular.otf
ac0535d7d4a8eb1b531c5faeb9060a4b9bac397d72cf54191ef53eea6f66b617  LatinModern/lmsans9-oblique.otf
80ef596460b7b402621780f7cd73a348efedc4cd2c6deca37da58f07ee61b85d  LatinModern/lmsans9-regular.otf
6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f  LatinModernMath/latinmodern-math.otf
95bc2729e41faf93b0bcae9e96c4dc4da45855067fd0581e621e30734fe8d90b  STIXTwo/STIXTwoMath-Regular.otf
```
