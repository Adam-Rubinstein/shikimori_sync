@{
  NotesRel        = "01 - Base/05 - Anime"
  PostersRel      = "03 - Files/AnimePosters"

  UA              = "Rubas Obsidian Shikimori Sync"

  # Основной домен Shikimori (API, OAuth, ссылки shikimori_url в заметках). При смене домена правьте только это.
  SiteUrl         = "https://shikimori.io"
  # CDN обложек; можно не трогать. Переопределите, если у инстанса другой хост картинок.
  StaticUrl       = "https://desu.shikimori.one"

  DetailThrottle  = 3
  PosterThrottle  = 12
  BatchSize       = 50
  MaxScore        = 20

  ShikiCookie     = ""
  MinPosterBytes  = 8000
  CacheBust       = $true
}
