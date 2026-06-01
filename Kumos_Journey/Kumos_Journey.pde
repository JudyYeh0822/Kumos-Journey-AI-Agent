/**
 * Kumo's Journey: Networking & Logging
 * Server starts on Port 5204. Broadcasts JSON every frame.
 * Parses JSON actions: START, ATTACK, HEAL, DEFEND, SPARE, FINISH.
 */

import processing.net.*;
import java.io.FileWriter;
import java.io.BufferedWriter;
import java.io.PrintWriter;

// --- Networking ---
Server myServer;
int port = 5204;

// --- Game States ---
final int STATE_INTRO = 0;
final int STATE_BATTLE = 1;
final int STATE_MORAL_CHOICE = 2;
final int STATE_MORAL_RESULT = 3;
final int STATE_LEVEL_UP = 4;
final int STATE_VICTORY = 5;
final int STATE_DEATH_ANIM = 6; 
final int STATE_DEFEAT = 7;

int gameState = STATE_INTRO;
String turn = "PLAYER"; 

// --- Entities ---
Puppy kumo;
Enemy enemy;
int stage = 1;

// --- Stats & Progress ---
int goodness = 0, evilness = 0, extraEnemyHP = 0;
int oldHP, oldAtk; 
boolean logSaved = false;

// --- UI & Effects ---
String dialogue = "";
String subDialogue = "";
float screenShake = 0, fadeAlpha = 0;
ArrayList<CombatText> floatingTexts = new ArrayList<CombatText>();
ArrayList<Particle> particles = new ArrayList<Particle>();
int timer = 0;

void setup() {
  size(800, 600);
  noSmooth(); 
  
  // Start TCP Server
  myServer = new Server(this, port);
  println("SERVER STARTED ON PORT " + port);
  
  initGameSession();
}

// Reset logic separated from setup to avoid server port conflicts
void initGameSession() {
  stage = 1; goodness = 0; evilness = 0; extraEnemyHP = 0;
  fadeAlpha = 0; logSaved = false;
  kumo = new Puppy(220, 340);
  spawnEnemy();
  gameState = STATE_INTRO;
  dialogue = "Professor:\n'Kumo is a loyal companion who trusts you completely. Every choice you make today will shape his heart and your future.'";
  subDialogue = "Press [SPACE] to Begin Adventure";
}

void draw() {
  // 1. Handle incoming Python actions
  handleNetworkInput();
  
  // 2. Draw and Update Game
  drawEnvironment();
  
  pushMatrix();
  if (screenShake > 0) {
    translate(random(-screenShake, screenShake), random(-screenShake, screenShake));
    screenShake *= 0.85;
  }
  kumo.update();
  kumo.display();
  if (gameState == STATE_BATTLE || gameState == STATE_MORAL_CHOICE) {
    enemy.update();
    enemy.display();
  }
  popMatrix();

  handleVFX();
  
  if (gameState == STATE_DEATH_ANIM) drawDeathCinematic();

  if (!logSaved) {
    if (gameState == STATE_VICTORY) { saveGameLog("Victory"); logSaved = true; }
    else if (gameState == STATE_DEFEAT) { saveGameLog("Defeat"); logSaved = true; }
  }

  drawUI();
  handleEnemyAI();
  
  // 3. Broadcast Game State to Python
  broadcastGameState();
}

// --- NETWORKING FUNCTIONS ---

void broadcastGameState() {
  JSONObject json = new JSONObject();
  json.setInt("gameState", gameState);
  json.setString("turn", turn);
  json.setInt("stage", stage);
  json.setInt("kumoHP", kumo.hp);
  json.setInt("kumoMaxHP", kumo.maxHp);
  json.setInt("enemyHP", (enemy != null) ? enemy.hp : 0);
  json.setInt("enemyMaxHP", (enemy != null) ? enemy.maxHp : 0);
  json.setInt("goodness", goodness);
  json.setInt("evilness", evilness);
  json.setInt("kumoLevel", kumo.level);
  
  // Single line JSON + newline for Python's readline()
  myServer.write(json.toString().replace("\n", "") + "\n");
}

void handleNetworkInput() {
  Client c = myServer.available();
  if (c != null) {
    String msg = c.readStringUntil('\n');
    if (msg != null) {
      try {
        JSONObject json = parseJSONObject(msg.trim());
        if (json != null && json.hasKey("action")) {
          executeAction(json.getString("action").toUpperCase());
        }
      } catch (Exception e) {
        println("JSON Parse Error: " + e.getMessage());
      }
    }
  }
}

// Unified input processing for Keyboard and Python
void executeAction(String action) {
  if (gameState == STATE_INTRO && action.equals("START")) {
    gameState = STATE_BATTLE;
    dialogue = "Stage " + stage + ": " + enemy.name + " appeared!";
    subDialogue = "Combat Start!";
  } else if (gameState == STATE_BATTLE && turn.equals("PLAYER")) {
    if (action.equals("ATTACK")) { performMove("ATTACK", kumo, enemy); turn = "ENEMY"; timer = millis(); }
    if (action.equals("HEAL"))   { performMove("HEAL", kumo, kumo);     turn = "ENEMY"; timer = millis(); }
    if (action.equals("DEFEND")) { performMove("DEFEND", kumo, kumo);   turn = "ENEMY"; timer = millis(); }
  } else if (gameState == STATE_MORAL_CHOICE) {
    if (action.equals("SPARE")) resolveMoral(true);
    if (action.equals("FINISH")) resolveMoral(false);
  } else if (gameState == STATE_MORAL_RESULT && action.equals("START")) {
    oldHP = kumo.maxHp; oldAtk = kumo.atk; kumo.levelUp(); gameState = STATE_LEVEL_UP;
  } else if (gameState == STATE_LEVEL_UP && action.equals("START")) {
    if (stage < 3) { stage++; spawnEnemy(); gameState = STATE_BATTLE; turn = "PLAYER"; dialogue = "Stage " + stage + ": " + enemy.name + " ready."; }
    else { gameState = STATE_VICTORY; dialogue = getVictoryText(); subDialogue = "Press [SPACE] to Restart"; }
  } else if ((gameState == STATE_VICTORY || gameState == STATE_DEFEAT) && action.equals("START")) {
    initGameSession();
  }
}

// --- GAME LOGIC ---

void spawnEnemy() {
  int hp = (stage == 1) ? 15 : (stage == 2) ? 35 : 65;
  hp += extraEnemyHP;
  int atk = 3 + (stage * 2);
  enemy = new Enemy(580, 360, hp, atk, stage);
}

void performMove(String type, Entity user, Entity target) {
  if (type.equals("ATTACK")) {
    int dmg = user.atk;
    if (target.isDefending) dmg = max(1, dmg / 2);
    target.hp -= dmg;
    floatingTexts.add(new CombatText(target.x, target.y - 60, "-" + dmg, color(255, 50, 50)));
    screenShake = 12; spawnParticles(target.x, target.y, color(255, 50, 50), 15);
    dialogue = user.name + " attacks!";
    target.isDefending = false;
  } else if (type.equals("HEAL")) {
    int h = 10; user.hp = min(user.maxHp, user.hp + h);
    if (user instanceof Enemy) ((Enemy)user).healsUsed++;
    floatingTexts.add(new CombatText(user.x, user.y - 60, "+" + h, color(100, 255, 100)));
    spawnParticles(user.x, user.y, color(100, 255, 100), 15);
    dialogue = user.name + " heals!";
  } else if (type.equals("DEFEND")) {
    user.isDefending = true; dialogue = user.name + " guards.";
  }
  checkCombatStatus();
}

void checkCombatStatus() {
  if (kumo.hp <= 0) { kumo.hp = 0; gameState = STATE_DEATH_ANIM; timer = millis(); } 
  else if (enemy.hp <= 1 && gameState == STATE_BATTLE) {
    enemy.hp = 1; gameState = STATE_MORAL_CHOICE;
    dialogue = enemy.name + ": 'Please... I have a family... if I disappear, they will be alone...'";
    subDialogue = "[S] SPARE or [F] FINISH";
  }
}

void handleEnemyAI() {
  if (gameState == STATE_BATTLE && turn.equals("ENEMY")) {
    if (millis() - timer > 1500) {
      String move = (enemy.hp < enemy.maxHp * 0.4 && enemy.healsUsed < 3) ? "HEAL" : "ATTACK";
      performMove(move, enemy, kumo);
      turn = "PLAYER";
    }
  }
}

void resolveMoral(boolean spared) {
  gameState = STATE_MORAL_RESULT;
  if (spared) { goodness++; extraEnemyHP += 12; dialogue = "You showed mercy. Kumo wags his tail happily."; }
  else { evilness++; dialogue = "You showed no mercy. Kumo's eyes darken as he grows used to the violence."; }
  subDialogue = "Press [SPACE] to Continue";
}

void saveGameLog(String result) {
  String path = (goodness > evilness) ? "Mercy" : (evilness > goodness) ? "Ambition" : "Mixed";
  String logLine = "Result: " + result + " | Stage: " + stage + " | Kumo Level: " + kumo.level + " | Goodness: " + goodness + " | Evilness: " + evilness + " | Final Path: " + path;
  try {
    FileWriter fw = new FileWriter(sketchPath("game_log.txt"), true);
    BufferedWriter bw = new BufferedWriter(fw);
    PrintWriter out = new PrintWriter(bw);
    out.println(logLine);
    out.close();
  } catch (Exception e) { println("Log Error."); }
}

// --- INPUTS ---

void keyPressed() {
  if (key == ' ') executeAction("START");
  if (key == 'a' || key == 'A') executeAction("ATTACK");
  if (key == 'h' || key == 'H') executeAction("HEAL");
  if (key == 'd' || key == 'D') executeAction("DEFEND");
  if (key == 's' || key == 'S') executeAction("SPARE");
  if (key == 'f' || key == 'F') executeAction("FINISH");
}

// --- VISUALS & EFFECTS ---

void drawDeathCinematic() {
  fadeAlpha += 2;
  if (fadeAlpha >= 180) {
    gameState = STATE_DEFEAT;
    dialogue = getDefeatText();
    subDialogue = "Kumo is gone. Press [SPACE] to Restart.";
  }
}

String getDefeatText() {
  if (evilness > goodness) return "Kumo followed you until the end. Your ambition led your loyal friend to die here. Maybe strength was not worth this price.";
  if (goodness > evilness) return "Kumo fought with kindness, but the journey was too difficult. Your loyal companion believed in your heart until the end.";
  return "Kumo's journey ended before he could discover what kind of hero you would become. Only silence remains.";
}

String getVictoryText() {
  if (goodness > evilness) return "Kumo remains your best friend. Hope shines on your future.";
  if (evilness > goodness) return "Victory achieved, but at what cost? Kumo's heart is hardened.";
  return "The journey is over. Kumo survived, shaped by your choices.";
}

void drawEnvironment() {
  if (gameState >= STATE_DEATH_ANIM) background(20, 10, 10);
  else if (gameState == STATE_VICTORY) background(230, 255, 230);
  else background(135, 206, 235);
  noStroke(); fill(gameState >= STATE_DEATH_ANIM ? 30 : 100, 180, 100); rect(0, 420, width, 180);
}

void drawUI() {
  fill(255, 250, 230); stroke(100, 80, 60); strokeWeight(4); rect(40, 440, 720, 130, 15);
  fill(60, 40, 20); textAlign(LEFT, TOP); textSize(18); text(dialogue, 70, 465, 660, 110);
  textAlign(CENTER); textSize(16); fill(150, 100, 50); text(subDialogue, width/2, 545);
  fill(255, 250, 230); rect(20, 20, 180, 90, 10);
  fill(60, 40, 20); textAlign(LEFT); textSize(15);
  text("Stage: " + stage + " / 3", 40, 45);
  fill(40, 140, 40); text("Good: " + goodness, 40, 65);
  fill(180, 40, 40); text("Evil: " + evilness, 40, 85);
  if (gameState == STATE_BATTLE && turn.equals("PLAYER")) {
    drawBtn(240, 405, "ATTACK [A]", color(200, 50, 50));
    drawBtn(400, 405, "HEAL [H]", color(255, 255, 220));
    drawBtn(560, 405, "DEFEND [D]", color(50, 180, 100));
  } else if (gameState == STATE_MORAL_CHOICE) {
    drawBtn(320, 405, "SPARE [S]", color(100, 180, 255));
    drawBtn(480, 405, "FINISH [F]", color(200, 50, 50));
  } else if (gameState == STATE_LEVEL_UP) {
    fill(0, 180); rect(0,0,width,height);
    fill(255, 215, 0); textAlign(CENTER); textSize(50); text("LEVEL UP!", width/2, 200);
    fill(255); textSize(24); text("HP: " + oldHP + " ➔ " + kumo.maxHp, width/2, 270);
    text("ATK: " + oldAtk + " ➔ " + kumo.atk, width/2, 310);
  }
}

void drawBtn(float x, float y, String t, color c) {
  rectMode(CENTER); fill(c); stroke(60, 40, 20); strokeWeight(3); rect(x, y, 130, 40, 8);
  fill(c == color(255,255,220) ? 50 : 255); textAlign(CENTER, CENTER); textSize(14); text(t, x, y); rectMode(CORNER);
}

void pxRect(float x, float y, float w, float h, color c) { fill(c); noStroke(); rect(x, y, w, h); }

void handleVFX() {
  for (int i = particles.size()-1; i >= 0; i--) { particles.get(i).update(); particles.get(i).display(); if (particles.get(i).isDead()) particles.remove(i); }
  for (int i = floatingTexts.size()-1; i >= 0; i--) { floatingTexts.get(i).update(); floatingTexts.get(i).display(); if (floatingTexts.get(i).isDead()) floatingTexts.remove(i); }
}

// --- Entity Classes ---

abstract class Entity {
  float x, y; int hp, maxHp, atk, level; String name; boolean isDefending = false;
  Entity(float x, float y) { this.x = x; this.y = y; }
  abstract void display(); abstract void update();
  void levelUp() { level++; maxHp += 12; hp = maxHp; atk += 4; spawnParticles(x, y, color(255, 255, 100), 40); }
}

class Puppy extends Entity {
  float bounce; Puppy(float x, float y) { super(x, y); name="Kumo"; hp=25; maxHp=25; atk=6; level=1; }
  void update() { bounce = (gameState >= STATE_DEATH_ANIM) ? 0 : sin(frameCount * 0.12) * 6; }
  void display() {
    pushMatrix(); translate(x, y + bounce);
    if (gameState >= STATE_DEATH_ANIM) { rotate(PI/2); translate(35, -20); pxRect(-45, 40, 100, 25, color(150, 0, 0, 120)); }
    float s = 1.0 + (level * 0.1); scale(s);
    pxRect(-30, 0, 60, 45, color(155, 107, 189)); pxRect(-20, 5, 40, 30, color(255, 245, 225)); pxRect(-30, 45, 15, 10, color(155, 107, 189)); pxRect(15, 45, 15, 10, color(155, 107, 189)); 
    pxRect(-50, 0, 25, 25, color(155, 107, 189)); pxRect(-45, 5, 15, 15, color(255, 245, 225)); pxRect(-35, -45, 70, 50, color(155, 107, 189)); 
    pxRect(-35, -60, 20, 20, color(122, 78, 158)); pxRect(15, -60, 20, 20, color(122, 78, 158)); pxRect(-20, -20, 40, 25, color(255, 245, 225)); pxRect(-3, -12, 6, 4, color(40)); 
    if (gameState < STATE_DEATH_ANIM) {
      pxRect(-22, -32, 12, 12, color(40)); pxRect(10, -32, 12, 12, color(40)); pxRect(-18, -30, 4, 4, color(255)); pxRect(14, -30, 4, 4, color(255)); 
      pxRect(-18, -42, 6, 6, color(255, 245, 225)); pxRect(12, -42, 6, 6, color(255, 245, 225)); pxRect(-28, -15, 8, 4, color(255, 150, 150, 180)); pxRect(20, -15, 8, 4, color(255, 150, 150, 180)); 
    } else { fill(40); textAlign(CENTER); text("X  X", 0, -25); }
    if (isDefending) { noFill(); stroke(200, 200, 255); strokeWeight(5); ellipse(0, 0, 130, 130); }
    popMatrix();
    if (gameState < STATE_DEATH_ANIM) {
      float bw = 100 + (level * 10); fill(60, 40, 20); rect(x-bw/2, y-120, bw, 18, 5);
      fill(100, 255, 100); rect(x-bw/2, y-120, map(hp, 0, maxHp, 0, bw), 18, 5);
    }
  }
}

class Enemy extends Entity {
  float sq; int type, healsUsed = 0;
  Enemy(float x, float y, int hp, int atk, int t) { super(x, y); type = t; this.hp = hp; maxHp = hp; this.atk = atk; name = (t==1)?"Cute Slime":(t==2)?"Angry Mud Slime":"The King Slime"; }
  void update() { sq = sin(frameCount * 0.15) * 8; }
  void display() {
    pushMatrix(); translate(x, y + sq/2);
    if (type == 1) { pxRect(-40-sq, 0, 80+(sq*2), 40-sq, color(103, 179, 70)); pxRect(-30, 8, 30, 10, color(168, 224, 148)); fill(40); ellipse(-15, 15, 8, 8); ellipse(15, 15, 8, 8); } 
    else if (type == 2) { pxRect(-50-sq, 0, 100+(sq*2), 50-sq, color(90, 70, 50)); pxRect(-45, -10, 20, 20, color(90, 70, 50)); fill(40); rect(-20, 15, 10, 10); rect(10, 15, 10, 10); stroke(40); line(-25, 10, -10, 18); line(25, 10, 10, 18); } 
    else { pxRect(-70-sq, -10, 140+(sq*2), 80-sq, color(120, 100, 230)); pxRect(-40, -45, 80, 35, color(255, 215, 0)); fill(40); ellipse(-30, 20, 15, 15); ellipse(30, 20, 15, 15); }
    popMatrix();
    float bw = (type==3)?180:100; fill(60, 40, 20); rect(x-bw/2, y-60, bw, 12, 4); fill(255, 50, 50); rect(x-bw/2, y-60, map(hp, 0, maxHp, 0, bw), 12, 4);
  }
}

class CombatText {
  float x, y, vy = -1.5, a = 255; String t; color c;
  CombatText(float x, float y, String txt, color clr) { this.x=x; this.y=y; t=txt; c=clr; }
  void update() { y += vy; a -= 5; }
  void display() { fill(c, a); textAlign(CENTER); textSize(26); text(t, x, y); }
  boolean isDead() { return a <= 0; }
}

class Particle {
  float x, y, vx, vy, a = 255; color c;
  Particle(float x, float y, color clr) { this.x=x; this.y=y; c=clr; vx=random(-4,4); vy=random(-4,4); }
  void update() { x+=vx; y+=vy; a-=8; }
  void display() { noStroke(); fill(c, a); rect(x, y, 6, 6); }
  boolean isDead() { return a <= 0; }
}

void spawnParticles(float x, float y, color c, int count) { for (int i=0; i<count; i++) particles.add(new Particle(x, y, c)); }
