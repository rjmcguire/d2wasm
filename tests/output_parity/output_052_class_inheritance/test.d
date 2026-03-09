class Animal {
    int legs;

    int sound() {
        return 0;
    }

    int legCount() {
        return legs;
    }
}

class Dog : Animal {
    int tricks;

    int sound() {
        return 1;
    }

    int score() {
        return tricks * 10;
    }
}

class Puppy : Dog {
    int cuteness;

    int sound() {
        return 2;
    }

    int totalScore() {
        return score() + cuteness;
    }
}

int getSound(Animal a) {
    return a.sound();
}

int main() {
    Puppy p;
    p.legs = 4;
    p.tricks = 3;
    p.cuteness = 7;

    int s = getSound(p);       // virtual dispatch -> Puppy.sound() = 2
    int l = p.legCount();      // inherited from Animal = 4
    int t = p.totalScore();    // score() + cuteness = 30 + 7 = 37

    return s + l + t;  // 43
}
