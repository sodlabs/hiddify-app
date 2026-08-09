# Projet : VPN gratuit auto-alimenté (nom de code "sodlab")

## Objectif
Un VPN mobile gratuit avec bouton on/off. L'app fetch et teste elle-même,
en local sur l'appareil de chaque utilisateur, des proxies publics gratuits
(gfpcom/free-proxy-list), priorité VLESS/Reality. Warning multilingue
(3rd party proxy, ne pas entrer d'infos sensibles). Distribution
pseudonyme : le frère d'Al (basé au Canada) est le nom public/porteur pour
toute publication sur les stores. Rien ne doit être lié à Al ni à la Russie.

## Pourquoi ce pivot (contexte légal)

Depuis mars 2024, la loi russe interdit la diffusion d'informations sur les
outils de contournement de la censure, **y compris des listes de services
qui fonctionnent** — et l'application s'est durcie en 2025 (amendes
élargies aux fournisseurs de VPN et à la recherche de contenu via VPN).
Publier un service centralisé qui teste/agrège/republie une liste de
proxies fonctionnels, sous une identité liée à Al en Russie, était un vrai
risque, pas théorique. D'où la décision : **zéro serveur, zéro liste
curatée publiée sous une identité identifiable** — tout le fetch et le
test se font en local, sur l'appareil de l'utilisateur final, à partir de
listes déjà publiques (gfpcom), sans qu'Al n'agrège ni ne republie rien.

Rappel important, non résolu : ceci réduit le risque lié au *sondage actif*
et à la *publication d'une liste curatée*, mais ne constitue pas un avis
juridique. Al a été encouragé à consulter une organisation spécialisée
(Roskomsvoboda, Net Freedoms) pour un avis concret sur son cas.

## Ancienne architecture (abandonnée, gardée en référence historique)

3 repos sous le compte GitHub personnel `allanjoshuaf` :
- `gfp-fetcher` : script Node.js tournant sur le PC d'Al en Russie
  (fetch + parse + test TCP/TLS + publish vers git, en Planificateur de
  tâches Windows toutes les 20 min)
- `gfp-subscription` : repo public contenant `subscription.txt` généré
- `hiddify-app` (fork) : app Flutter, consommait l'URL de subscription

Cette architecture a été entièrement bâtie et validée bout en bout
(VPN fonctionnel testé avec succès sur téléphone en Russie), mais est
abandonnée pour la nouvelle version à cause du risque légal identifié
ci-dessus. Le code reste utile comme référence pour porter la logique en
Dart (voir plan de migration).

Point technique utile capitalisé au passage : un vrai bug upstream dans
hiddify a été trouvé et signalé — `ci.yml` n'assigne jamais `channel: prod`
à `build.yml`, donc `CHANNEL` retombe sur `"dev"` et le Makefile télécharge
le core natif **"draft"** (mouvant) au lieu de la version épinglée dans
`dependencies.properties`, cassant la compilation Kotlin. Fix : workflow
séparé (`custom-android-build.yml`) qui force `channel: prod`. Utile si on
refork un jour hiddify pour autre chose.

## Nouvelle architecture (en cours de mise en place)

**100% client-side.** L'app (fork hiddify ou plugin sing-box standalone,
décision technique encore ouverte) fait elle-même, en local :
1. Fetch des listes brutes gfpcom directement depuis
   `raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/*.txt`
   (infrastructure publique, pas la nôtre)
2. Parse + dédup + priorité (reality > vless > vmess > trojan) — port Dart
   de la logique déjà écrite et testée dans `gfp-fetcher/src/parseProxies.js`
3. Test de joignabilité (TCP puis TLS si SNI présent) — port Dart de
   `gfp-fetcher/src/tester.js` (attention : bug déjà rencontré une fois,
   `servername` TLS ne peut jamais être une IP, cf. `net.isIP()` côté Node,
   équivalent à vérifier côté Dart)
4. Cache local des résultats (vitesse au démarrage, économie data/batterie,
   filet de secours hors-ligne) — TTL à définir (30-60 min ?)
5. Limite d'agressivité du test selon Wi-Fi vs données mobiles
   (`connectivity_plus` en Flutter) : illimité à la maison, throttle ailleurs

Aucune télémétrie, aucune remontée de résultats vers un serveur, même
anonymisée — décision explicite pour ne pas réintroduire un point central
de données. Pourra être reconsidéré bien plus tard, séparément.

Zéro backend nécessaire pour la V1 : l'app parle uniquement à gfpcom
(infra publique tierce) et, plus tard, aux stores pour les mises à jour.
Toute infra future (si besoin un jour) passera par le serveur canadien du
frère d'Al, jamais depuis la Russie.

## Plan de migration — checklist concrète

### Comptes / identité
- [ ] Créer un compte GitHub `sodlab` séparé (email dédié, non lié à Al),
      distinct de `allanjoshuaf`
- [ ] Décider de l'identité git des commits sur ce nouveau compte (email
      dédié au projet, pas l'email perso d'Al)

### Repos à fermer / nettoyer (sous `allanjoshuaf`)
- [ ] **Supprimer** `gfp-subscription` — plus d'utilité dans la nouvelle
      architecture, et c'est littéralement "une liste de services qui
      marchent" publiée sous une identité liée à Al. Pas juste privé :
      supprimer.
- [ ] **Désactiver la tâche planifiée Windows** qui lance `gfp-fetcher`
      (Planificateur de tâches → trouver la tâche `gfp-fetcher` → désactiver
      ou supprimer). Plus besoin de process qui tourne en continu.
- [ ] `gfp-fetcher` : passer en repo **privé** par précaution (le code seul
      n'est pas une liste de proxies vivante, mais autant limiter
      l'exposition). Garder pour référence/portage, pas besoin de
      supprimer.
- [ ] `hiddify-app` (fork sous `allanjoshuaf`) : **ne pas transférer** vers
      le nouveau compte — un transfert GitHub garde l'historique de commits
      (donc le nom/email d'Al dedans). Mieux vaut repartir d'un fork frais
      sous `sodlab` directement depuis `hiddify/hiddify-app`, et réappliquer
      seulement les fichiers utiles en tant que commits neufs sous la
      nouvelle identité. L'ancien fork peut rester tel quel (juste du code
      d'app hiddify, risque faible en soi) ou être supprimé, au choix d'Al.

### Nouveau repo sous `sodlab`
- [ ] Fork frais de `hiddify/hiddify-app` (si on garde cette base — sinon
      nouveau projet Flutter avec plugin sing-box standalone, décision
      technique à prendre au démarrage du travail Android)
- [ ] Régénérer les secrets de signature Android dans les Settings de ce
      nouveau repo (`ANDROID_SIGNING_KEY`, `ANDROID_SIGNING_STORE_PASSWORD`,
      `ANDROID_SIGNING_KEY_PASSWORD`, `ANDROID_SIGNING_KEY_ALIAS`) — le
      même keystore déjà généré peut être réutilisé tel quel, ce n'est pas
      un identifiant personnel, juste une paire de clés crypto
- [ ] Ajouter `custom-android-build.yml` (channel=prod) et
      `sync-upstream.yml` dans ce nouveau repo
- [ ] Réécrire `home_page.dart` / l'UI pour le nouveau modèle 100%
      client-side (fetch+test local, plus d'URL de subscription à
      pré-remplir) — c'est le vrai chantier de dev à venir après ce
      nettoyage

### Hygiène générale à garder en tête
- Vérifier qu'aucun chemin/nom de machine Windows personnel ne fuite dans
  les commits, logs de build, ou strings embarquées dans l'app
- Compte développeur Google Play / Apple : les deux exigent une identité
  vérifiée (pièce d'identité + infos bancaires) pour publier, même en
  pseudonyme — le frère d'Al devra être ce compte développeur officiel,
  pas juste un nom affiché. À prévoir séparément, pas urgent aujourd'hui.

## Ordre de travail décidé
1. Nettoyage/migration ci-dessus — FAIT
2. Android d'abord (nouveau fetch+test 100% client-side) — EN COURS
   - [x] Nouveau fork `sodlab/hiddify-app` créé, secrets Android régénérés
         (nouvelle clé, l'ancienne a été perdue avant publication, sans
         conséquence), `custom-android-build.yml` + `sync-upstream.yml`
         recréés
   - [x] Code Dart écrit : `lib/features/gfp/` (models, parser, tester,
         service) + `home_page.dart` réécrit pour fetch+test 100%
         client-side via `ProfileRepository.addLocal`/`offlineUpdate`
         (plus d'URL de subscription hébergée par nous)
   - [x] **Build réussi du premier coup** (android-apk, android-aab, linux
         tous verts) — bon signe que le check-list de migration a bien
         fonctionné
   - [ ] Test réel sur téléphone en cours (fetch+test au premier lancement,
         création auto du profil "sodlab (auto, non verifie)", connexion)
3. iPhone ensuite (Al a un iPhone personnel, pourra tester réellement)
4. Windows : optionnel, plus tard

## Pièges déjà rencontrés (toujours valables, gardés pour référence)

- Un vrai token GitHub a été accidentellement commité via `.env` avant la
  mise en place du `.gitignore`. Il a été révoqué. Toujours vérifier
  `git status` avant de commit un `.env`.
- `run.js` (ancien fetcher) ne chargeait pas `.env` au démarrage → corrigé
  avec `require('dotenv').config()`.
- `raw.githubusercontent.com` renvoie **404** (pas 403) sur un repo privé.
- `tls.connect({ servername })` plante si `servername` est une adresse IP
  (le SNI doit être un nom d'hôte) — à re-vérifier lors du portage Dart.
- Build Android hiddify : voir section bug upstream `channel=prod` plus
  haut si jamais on refork hiddify pour la nouvelle version.
