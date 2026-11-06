package android.accounts;

// roam-helpers fake. Like the real one, toString() carries the NAME -- which is why the helpers never print a message.
public class Account {
    public final String name, type;

    public Account(String name, String type) {
        this.name = name;
        this.type = type;
    }

    @Override
    public String toString() {
        return "Account {name=" + name + ", type=" + type + "}";
    }
}
