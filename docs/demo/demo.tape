# The README demo: three scenes, each refusal and message produced by the real
# plugin code from ../../plugins. Re-record from this folder with:
#   vhs demo.tape
# demo.sh sets up the sandbox and the helpers typed below; see its header.

Output demo.gif
Output demo.txt

Require node
Require jq

Set Shell bash
Set FontFamily "Menlo"
Set FontSize 22
Set Width 1200
Set Height 650
Set Padding 24
Set Theme "GitHub Dark"
Set WindowBar Colorful
Set Framerate 30
Set TypingSpeed 28ms
Set CursorBlink false
# Every pause starts once the command has finished and the prompt is back, so a
# busy machine can't make the next command start typing over late output.
Set WaitPattern /\$ *$/
Set WaitTimeout 20s

# Scene 1: git-guardrails
Hide
Type "source demo.sh && caption 1"
Enter
Wait
Show
Sleep 700ms
Type "pretooluse 'gh pr merge 12 --squash'"
Sleep 250ms
Enter
Wait
Sleep 3s
Type "pretooluse 'git push origin main'"
Sleep 250ms
Enter
Wait
Sleep 3.2s

# Scene 2: machine-pressure
Hide
Type "caption 2"
Enter
Wait
Show
Sleep 600ms
Type "pressure.sh --statusline"
Sleep 250ms
Enter
Wait
Sleep 1.5s
Type "pretooluse 'npx playwright test'"
Sleep 250ms
Enter
Wait
Sleep 3.6s

# Scene 3: agent-chat. two-agents draws the panes, then holds the last frame
# long after the recording stops.
Hide
Type "caption 3; two-agents"
Enter
Wait+Screen /web agent/
Show
Wait+Screen /web: Yes/
Sleep 3.4s

Hide
Ctrl+C
Wait
Type 'rm -rf "$DEMO_SANDBOX"'
Enter
Sleep 200ms
