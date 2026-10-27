# How to create a quest

A Meander quest is a set of nodes (screens) and links between them. The player sees a node, presses buttons, and you decide what happens next. Here is the path from an empty project to publishing.

## 1. Create a project

Open **My quests** and press **Create quest**. You get an empty project with a start node, so you do not begin from scratch.

- You can change the title and cover later — do not get distracted by them now.
- Long quests can be split into chapters: it keeps things organised.

## 2. Build a screen

Open a node and add content: text, an image, a button, an input field. Everything is a block. The order of blocks on the screen matches the order in the list.

- Use a library image or a solid colour for the background.
- A button without an action looks functional but does nothing: give it an event right away.

## 3. Set up events

A node has events. The most common one is **on press**: it decides what happens when the player taps a button.

- **On enter** — code runs when the player enters the node.
- **On press** — the reaction to a button.
- **On variable change** — the reaction to a new value.

Variables hold the state of the game: health, money, found items. You can change them and check them in conditions.

## 4. Connect nodes with links

A link joins two nodes. For example, a “Go on” button leads from a room into a corridor.

- Mark the **start node** — that is where the game begins.
- Make sure every node has an exit: otherwise the player gets stuck.
- A link can be conditional: it fires only when a condition is met.

## 5. Playtest and publish

Press **Play** to go through the quest the way a player will. Check the text, buttons and links — especially dead ends.

When everything is ready, send the quest for moderation. Once approved, it appears in the market. The tidier the screens and the clearer the story, the better the chance of being featured.

> Tip: start with a short scene of 5–10 nodes. A finished small quest teaches more than a large unfinished one.
