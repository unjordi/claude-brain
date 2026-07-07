using System.Text.Json.Serialization;

namespace ClaudeQuota;

// ---------------------------------------------------------------------------
// state.json (límites) — same schema the bash/mac fetch writes, so the cache is
// interchangeable and debuggable across platforms.
// ---------------------------------------------------------------------------

/// <summary>One usage bucket (5-hour block or weekly).</summary>
public sealed class Bucket
{
    [JsonPropertyName("percent")]    public double? Percent { get; set; }
    [JsonPropertyName("cost_usd")]   public double? CostUsd { get; set; }
    [JsonPropertyName("cost_cap")]   public double? CostCap { get; set; }
    [JsonPropertyName("tokens_used")] public double? TokensUsed { get; set; }
    [JsonPropertyName("resets_at")]  public string? ResetsAt { get; set; }
}

/// <summary>The full state.json snapshot.</summary>
public sealed class Snapshot
{
    [JsonPropertyName("updated_at")]    public string? UpdatedAt { get; set; }
    [JsonPropertyName("status")]        public string? Status { get; set; }
    [JsonPropertyName("basis")]         public string? Basis { get; set; }   // "oauth" | "cost"
    [JsonPropertyName("account_email")] public string? AccountEmail { get; set; }
    [JsonPropertyName("account_uuid")]  public string? AccountUuid { get; set; }
    // True when an account is pinned (config file) and the active one differs.
    [JsonPropertyName("account_mismatch")] public bool AccountMismatch { get; set; }
    [JsonPropertyName("error")]         public string? Error { get; set; }
    [JsonPropertyName("five_hour")]     public Bucket? FiveHour { get; set; }
    [JsonPropertyName("weekly")]        public Bucket? Weekly { get; set; }
}

// ---------------------------------------------------------------------------
// stats.json (uso local) — powers the Resumen / Modelos tabs.
// ---------------------------------------------------------------------------

public sealed class Stats
{
    [JsonPropertyName("updated_at")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("days")]       public List<StatsDay>? Days { get; set; }
    [JsonPropertyName("models")]     public List<StatsModel>? Models { get; set; }
    [JsonPropertyName("projects")]   public List<StatsProject>? Projects { get; set; }
    [JsonPropertyName("summary")]    public StatsSummary? Summary { get; set; }
}

public sealed class StatsDay
{
    [JsonPropertyName("date")]    public string? Date { get; set; }
    [JsonPropertyName("in_tok")]  public double InTok { get; set; }
    [JsonPropertyName("out_tok")] public double OutTok { get; set; }
    [JsonPropertyName("tokens")]  public double Tokens { get; set; }
    [JsonPropertyName("cost")]    public double? Cost { get; set; }
    [JsonPropertyName("models")]  public List<DayModel>? Models { get; set; }
    [JsonPropertyName("projects")] public List<DayProject>? Projects { get; set; }
}

public sealed class DayModel
{
    [JsonPropertyName("model")]  public string? Model { get; set; }
    [JsonPropertyName("tokens")] public double Tokens { get; set; }
}

public sealed class DayProject
{
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("tokens")]  public double Tokens { get; set; }
}

/// <summary>Claude-only usage by project folder (~/.claude/projects/&lt;slug&gt;).
/// On Windows this is derived from the same transcript parse as the Modelos tab,
/// so the totals agree (no separate agent CLIs mixed in, unlike ccusage).</summary>
public sealed class StatsProject
{
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("in_tok")]  public double InTok { get; set; }
    [JsonPropertyName("out_tok")] public double OutTok { get; set; }
    [JsonPropertyName("tot")]     public double Tot { get; set; }
    [JsonPropertyName("pct")]     public double Pct { get; set; }
}

public sealed class StatsModel
{
    [JsonPropertyName("model")]   public string? Model { get; set; }
    [JsonPropertyName("in_tok")]  public double InTok { get; set; }
    [JsonPropertyName("out_tok")] public double OutTok { get; set; }
    [JsonPropertyName("cost")]    public double? Cost { get; set; }
    [JsonPropertyName("tot")]     public double Tot { get; set; }
    [JsonPropertyName("pct")]     public double Pct { get; set; }
}

public sealed class StatsSummary
{
    [JsonPropertyName("total_tokens")]   public double TotalTokens { get; set; }
    [JsonPropertyName("total_cost")]     public double? TotalCost { get; set; }
    [JsonPropertyName("active_days")]    public int ActiveDays { get; set; }
    [JsonPropertyName("favorite_model")] public string? FavoriteModel { get; set; }
    [JsonPropertyName("sessions")]       public double Sessions { get; set; }
    [JsonPropertyName("messages")]       public double Messages { get; set; }
    [JsonPropertyName("peak_hour")]      public int PeakHour { get; set; }

    // Internal channel: ccusage bucket costs feed the Límites tab, not stats.json.
    [JsonIgnore] public double? FiveHourCost { get; set; }
    [JsonIgnore] public double? WeeklyCost { get; set; }
}

// ---------------------------------------------------------------------------
// Anthropic OAuth /usage response (subset we consume).
// ---------------------------------------------------------------------------

public sealed class OAuthUsage
{
    [JsonPropertyName("five_hour")] public OAuthWindow? FiveHour { get; set; }
    [JsonPropertyName("seven_day")] public OAuthWindow? SevenDay { get; set; }
}

public sealed class OAuthWindow
{
    [JsonPropertyName("utilization")] public double? Utilization { get; set; }
    [JsonPropertyName("resets_at")]   public string? ResetsAt { get; set; }
}
