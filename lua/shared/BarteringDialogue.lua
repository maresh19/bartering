local BarteringDialogue = {}

BarteringDialogue.NOTHING_NEEDED = "Nothing I need right now. Ask me again in %s."

BarteringDialogue.Radio = {
    onTheWay = "*tzzt* I'm on my way.*tzzt* I'll be there in about %s",
    amendsOnTheWay = "*tzzt* I'm coming over so you can make this right. *tzzt* Be there in about %s",
    arriving = "*tzzt* I can see the meetup spot now. *tzzt* Just a second. *tzzt*",
    waitingAtMeetup = "*tzzt* I'm at the meetup spot. *tzzt* I'll hang around another %s, then I'm heading home.",
    stockList = "*tzzt* Here's what I've got. *tzzt*",
    nothingNeeded = BarteringDialogue.NOTHING_NEEDED,
    prompt = "*tzzt*",
    headingHome = "Hey I'm on my way home right now, did you need something?",
    otherMeetup = "Hey I'm on my way to a meetup currently, what's up?",
    busyAtMeetup = "Hey im in the middle of something, call me back in %s",
}

BarteringDialogue.FaceToFace = {
    unknown = "The barterer watches you in silence.",
    thanks = "Much obliged. That means something to me - I won't forget it.",
    nothingNeeded = BarteringDialogue.NOTHING_NEEDED,
    introduced = "Name's %s. Im always looking to trade, and now and then I could use an extra hand. Talk to me.",
    greeting = "Good to see you still breathing. Got something for me?",
    hired = "Well I guess this isn't the worst job I've had, did you need something?",
}

BarteringDialogue.Movement = {
    doorLocked = "Hey your doors locked! I cant get in!",
    noRouteIn = "I cant find a way in from here!",
    noRoute = "I cant find a way to you from here!",
}

BarteringDialogue.Intercept = {
    askStayHere = "You want to just trade out here or should I continue to the meetup spot?",
    unsafe = "We're going to get ourselves killed out here, I'll see you at the meetup point",
    declined = "Alright, I'll see you at the meetup spot",
    timedOut = "I'll be at the meetup spot",
    tooCrowded = "We're going to get killed trying to trade out here",
    tooManyAggroed = "If you want to trade here then help me out, otherwise head back and I'll follow behind",
}

BarteringDialogue.Call = {
    noAnswer = "Oh no... no one's answering..",
    injured = "I'm laid up right now and won't be back in %s",
    permanentlyDead = "This channel's dead, buddy. Nothing's picking up.",
    alreadyEnRoute = "I'm already on my way. I'll be there in %s",
    relationshipTooLow = "I don't know you well enough for radio calls",
    sleepingNoAnswer = "No response, he must be sleeping",
    strangerOnRadio = "Who is this? We ain't met. Come see me face to face.",
    alreadyHere = "I'm already here, ain't I?",
    areaInfested = "Last I heard that area was way too infested, sorry buddy",
    accepted = "Hey, yeah I can be there in about %s",
    amendsAccepted = "Fine. I'll come over so you can make this right. I'll be there in about %s",
    nearbyBlocked = "Wait what? You're basically right next to me, just come to me.",
    tooLateHeadingHome = "It's way too late to be heading out at this point, call me back tomorrow",
    otherMeetup = "I'm currently heading to meetup with someone else, call me back in %s",
    tooLateAfterMeetup = "Sorry, its going to be too late at that point, youll have to call me back tomorrow",
}

BarteringDialogue.SaleCall = {
    message = "*tzzt* %s here. Sale's on today. Come by if you're wantin' a deal. *tzzt*",
}

BarteringDialogue.Blocked = {
    relationshipTooLow = "Requires Level %d Relationship With This Barterer",
    arrangeMeeting = "Arrange a meeting with ",
}

BarteringDialogue.Hostility = {
    greeting = "Why would you think i'd want to talk to you right now",
    amendsResponse = "What you did was pretty messed up, but if you make it worth my while, then consider it forgiven.",
    costNote = "(Give the barterer %s trade value to decrease hostility)",
    readyToForgive = "Alright if you can make it worth my while, I'm ready to forgive you",
    forgiven = "Alright, we're square. Just don't pull that again.",
}

BarteringDialogue.Hire = {
    needMoreRelationship = "I need to know you better before I'll work for you",
    alreadyHired = "I'm already on the job",
    cantHireOverRadio = "You'll have to ask me in person",
    accepted = "You've got yourself a deal. I'll follow you for %s",
    expired = "My time's up, I'm heading out",
    leavingSoon = "Hey im going to be leaving soon, if you want me to stay longer then give me more stuff",
    workingRefusal = "Hey I'm doing a job for someone, cant talk right now.",
    disabled = "Hiring isn't allowed in this world",
    sendHomeConfirm = "Are you sure? I'm still working for you for another %d hours and %d minutes",
}

BarteringDialogue.SendHome = {
    confirm = "Are you sure?",
}

BarteringDialogue.Sentiment = {
    tool = "There's none other like it.",
    lines = {
        "It means a lot to me.",
        "Had that thing since before any of this started.",
        "Never got the chance to go back for it.",
        "It's about the last thing I've got left from that life.",
        "Lost enough already without losing that too.",
        "I've replaced everything else twice over. Not that.",
        "You could say I'm attached to it.",
    },
}

BarteringDialogue.QuestFlavor = {
    video = {
        "See if %s in %s still has a copy of '%s' on VHS. I never had a chance to watch it.",
        "Go check %s in %s for a copy of '%s'. It reminds me of the old days.",
    },
    music = {
        "Get me a copy of '%s' from %s in %s. I never had a chance to listen to it.",
        "Go check %s in %s for a copy of '%s'. It reminds me of the old days.",
    },
    liquor = "I need a drink, but I only drink the finest bourbons. Find me a %s from %s in %s and I'll make it worth your while.",
    medicine = "I need a bottle of %s. %s There should be some at %s in %s. Bring it back and I'll make it worth your while.",
    necklace = {
        "I had a place over in %s before all this. My %s is still sitting in the %s there. It means the world to me. Bring it back.",
        "If your going to be in %s, My %s is still in the %s at my old place. If you could bring it back to me I'd be forever thankful.",
    },
    picture = {
        "See if you can find my %s's picture. It should be in the %s at my old place in %s. I'd like to know it's safe.",
        "I'm looking for a picture of my %s. It should be somewhere in the %s at my old place in %s It'd really lift my spirits if you could get that back to me.",
    },
    personalRoom = "I need my %s back. It's at my %s in %s. %s Bring it back to me.",
    namedPlace = "I left my %s at %s in %s. %s Bring it back to me.",
    anywhere = "I left my %s somewhere in %s in %s. %s Bring it back to me.",
    clothing = "I left my %s at my %s in %s when things went down. It should still be in my old bedroom. I feel naked without it. Bring it back to me.",
}

BarteringDialogue.QuestReminder = {
    handOver = "That's the one. Hand over my %s and we're square.",
    clothing = "Still nothing? My %s at my %s in %s. It's marked on your map.",
    recording = "Still nothing? A copy of '%s' from %s in %s. It's marked on your map.",
    liquor = "Still nothing? My bourbon from %s in %s. It's marked on your map.",
    medicine = "Still nothing? I need the %s from %s in %s. It's marked on your map.",
    necklace = "Still nothing? My %s, in the %s at my old place in %s. It's marked on your map.",
    picture = "Still nothing? A picture of my %s, in the %s at my old place in %s. It's marked on your map.",
    personalRoom = "Still nothing? %s. It's marked on your map.",
    generic = "Still nothing? %s in %s. It's marked on your map.",
    knownPlace = "my %s in %s",
    oldPlace = "my old place in %s, the %s",
    deadline = " You have %s left.",
}

BarteringDialogue.QuestLabel = {
    momsHouse = "mom's house",
    momsHouseTitle = "Mom's House",
    recording = "copy of '%s'",
    picture = "picture of my %s",
}

return BarteringDialogue
