# Code

Code is set in LM Mono, unjustified, with the list spacing above and below:

```
func breakLines(_ paragraph: Paragraph) -> [Line] {
    var active = [Breakpoint.start]
    for item in paragraph.items { consider(item, &active) }
    return cheapest(active)
}
```

The text continues after the code.
