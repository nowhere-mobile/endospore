package android.widget;
import android.content.Context;
import android.content.res.ColorStateList;
import android.view.View;
public class ImageView extends View {
    private int resource;
    private ColorStateList tint;
    public ImageView(Context c) { super(c); }
    public void setImageResource(int r) { resource = r; }
    public int imageResource() { return resource; }
    public void setImageTintList(ColorStateList t) { tint = t; }
    public ColorStateList getImageTintList() { return tint; }
}
