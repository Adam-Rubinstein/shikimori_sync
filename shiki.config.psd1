@{
  NotesRel        = "01 - Base/05 - Anime"
  PostersRel      = "03 - Files/AnimePosters"

  UA              = "Rubas Obsidian Shikimori Sync"

  # Основной домен Shikimori (API, OAuth). При смене домена правьте прежде всего это.
  SiteUrl         = "https://shikimori.io"
  # Ссылки в YAML (shikimori_url) в Obsidian; если пусто — как SiteUrl. Задайте явно при старом shiki.one в заметках.
  LinkSiteUrl     = "https://shikimori.io"
  # CDN обложек; можно не трогать. Переопределите, если у инстанса другой хост картинок.
  StaticUrl       = "https://desu.shikimori.one"

  # Одновременных запросов /api/animes/{id} (только PS7+). При 429 уменьшите до 2–3.
  DetailThrottle  = 5
  PosterThrottle  = 12
  BatchSize       = 50
  MaxScore        = 20

  ShikiCookie     = ""
  MinPosterBytes  = 8000
  CacheBust       = $true
  # Сначала скриншоты с карточки, потом image.* — у сиквелов чаще разные кадры, чем общий постер франшизы.
  PosterPreferScreenshot = $true
}
