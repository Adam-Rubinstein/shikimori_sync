#requires -Version 5.1
# Pester 5 — чистые функции из shiki.notes.psm1 (без сети и vault)

BeforeAll {
  $root = Split-Path -Parent $PSScriptRoot
  Import-Module (Join-Path $root 'shiki.notes.psm1') -Force -DisableNameChecking
}

Describe 'Sanitize' {
  It 'removes invalid path characters' {
    (Sanitize 'a:b*c?d"e<f>g|h') | Should -Be 'a b c d e f g h'
  }
}

Describe 'Get-RatingCanonical' {
  It 'normalizes common codes' {
    (Get-RatingCanonical 'pg-13') | Should -Be 'PG-13'
    (Get-RatingCanonical 'r') | Should -Be 'R-17'
  }
}

Describe 'Get-ScoreFromComment' {
  It 'parses first number in comment' {
    (Get-ScoreFromComment 'оценка 8.5 из 10' 10) | Should -Be 8.5
  }
  It 'returns null when no valid score' {
    (Get-ScoreFromComment 'без цифр' 10) | Should -Be $null
  }
}

Describe 'MakeTag' {
  It 'slugifies for tags' {
    (MakeTag 'Hello World') | Should -Be 'hello_world'
  }
}
