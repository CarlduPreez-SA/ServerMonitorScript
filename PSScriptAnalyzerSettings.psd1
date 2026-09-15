@{
    # PSUseSingularNouns flags any function ending in "Settings" (Get-Settings,
    # ConvertTo-ValidatedSettings, etc). "Settings" is a mass noun here - there's
    # no singular "Setting" object being returned, just the settings collection -
    # so renaming would make the API less clear. Excluded rather than papered
    # over with awkward names.
    ExcludeRules = @('PSUseSingularNouns')
}
